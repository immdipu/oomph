import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native alerts and panels. They run modally, so they work the same from the menu bar
/// popover, which can close underneath them, and from the equalizer window.
@MainActor
enum Dialogs {
    // MARK: - Unsaved edits (eqtune's rules)

    /// `eqtune off` stops at a save/discard question when presets have unsaved edits; by
    /// then the EQ is already off. This asks the same question.
    static func resolveAfterTurningOff(_ presets: [String], store: EqtuneStore) async {
        let verb = presets.count == 1 ? "has" : "have"
        switch ask("Save your changes?", "The EQ is off. \(list(presets, store)) \(verb) unsaved changes." + copyNote(presets, store)) {
        case .save: await store.saveAll()
        case .discard: await store.discardEditsAndTurnOff()
        case .cancel: break
        }
    }

    /// eqtune imports, duplicates, renames, deletes and resets presets only when no preset has
    /// unsaved edits. Asks to save or discard them; returns whether `change` may go ahead.
    static func resolveBeforeChanging(_ store: EqtuneStore) async -> Bool {
        // An edit on its way may be about to leave a preset unsaved: read status after it.
        if store.isBusy { await store.refresh() }
        guard store.hasUnsavedEdits, let dirty = store.status?.dirtyPresets else { return true }
        let verb = dirty.count == 1 ? "has" : "have"
        switch ask("Save your changes first?", "\(list(dirty, store)) \(verb) unsaved changes. Save or discard them to continue." + copyNote(dirty, store)) {
        case .save: await store.saveAll()
        case .discard: await store.discardAll()
        case .cancel: return false
        }
        return !store.hasUnsavedEdits && store.failure == nil
    }

    /// Saving everything never saves over a built-in: says where its changes go instead.
    private static func copyNote(_ presets: [String], _ store: EqtuneStore) -> String {
        let builtIns = presets.filter(EqtuneStore.isBuiltIn)
        guard !builtIns.isEmpty else { return "" }
        let copies = builtIns.count == 1 ? "“\(store.copyTitle(of: builtIns[0]))”" : "new presets"
        return " Built-in presets stay as they are, so changes to \(list(builtIns, store)) are saved as \(copies)."
    }

    // MARK: - Going back

    /// Puts `preset` back to its original state, after asking: the tuning it shipped with, or
    /// for one of the user's own, how it was last saved.
    static func reset(_ preset: String, store: EqtuneStore) async {
        if EqtuneStore.isBuiltIn(preset) { await resetToOriginal(preset, store: store) } else { await resetToSaved(store: store) }
    }

    /// Whether Reset has anything to put back for `preset`.
    static func canReset(_ preset: String, store: EqtuneStore) -> Bool {
        EqtuneStore.isBuiltIn(preset) || store.status?.dirtyPresets.contains(preset) == true
    }

    /// Throws away unsaved edits, after asking. eqtune can only discard every preset's edits
    /// at once (by restarting the EQ), so the question names everything that goes back.
    private static func resetToSaved(store: EqtuneStore) async {
        guard let status = store.status, !status.dirtyPresets.isEmpty else { return }
        let one = status.dirtyPresets.count == 1
        let alert = NSAlert()
        alert.messageText = "Reset to the last saved version?"
        alert.informativeText = "\(list(status.dirtyPresets, store)) \(one ? "goes" : "go") back to how \(one ? "it was" : "they were") last saved."
            + (status.isOn ? " The EQ restarts for a moment." : "")
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await store.discardAll()
    }

    /// Puts `preset` back to its original tuning, after asking.
    private static func resetToOriginal(_ preset: String, store: EqtuneStore) async {
        let item = SoundLibrary.preset(preset)
        // eqtune's `reset` refuses while any preset has unsaved edits. When they're only this
        // preset's, the reset replaces them anyway, so they go without asking a second time.
        let dropsItsEdits = item == nil && store.status?.dirtyPresets == [preset]
        let alert = NSAlert()
        alert.messageText = "Reset “\(store.displayName(preset))” to its original tuning?"
        alert.informativeText = "Your changes to this preset, saved or not, are replaced by its original version."
            + (dropsItsEdits && store.status?.isOn == true ? " The EQ restarts for a moment." : "")
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let item {
            await store.resetLibraryPreset(item)
            return
        }
        if dropsItsEdits {
            await store.discardAll()
        } else {
            guard await resolveBeforeChanging(store) else { return } // other presets' edits: ask
        }
        await store.resetPreset(preset)
    }

    /// Picks a library preset: a switch if eqtune has it already, otherwise an import.
    static func use(_ item: LibraryPreset, store: EqtuneStore) async {
        if store.presets.contains(item.id) {
            await store.selectPreset(item.id)
        } else if await resolveBeforeChanging(store) {
            await store.useLibraryPreset(item)
        }
    }

    private enum Choice { case save, discard, cancel }

    private static func ask(_ title: String, _ detail: String) -> Choice {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .save
        case .alertSecondButtonReturn: .discard
        default: .cancel
        }
    }

    private static func list(_ names: [String], _ store: EqtuneStore) -> String {
        ListFormatter.localizedString(byJoining: names.map { "“\(store.displayName($0))”" })
    }

    // MARK: - Files

    /// Asks for an eqtune preset or an Equalizer APO / AutoEq file and imports it.
    static func importPreset(store: EqtuneStore) async {
        let panel = NSOpenPanel()
        panel.message = "Choose an Oomph or eqtune preset (.toml), or a parametric EQ file from AutoEq or Equalizer APO (.txt)."
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data, .plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            await importPreset(text, named: PresetImport.suggestedName(for: url), store: store)
        } catch {
            store.failure = EqtuneStore.Failure(error)
        }
    }

    /// Imports a preset file's text, called `name` or a free name like it, and says which
    /// filters it couldn't use. Returns the new preset's name, or nil if nothing was imported.
    @discardableResult
    static func importPreset(_ text: String, named name: String, store: EqtuneStore) async -> String? {
        do {
            let title = store.availableTitle(name)
            let result = try PresetImport.read(text, name: store.name(for: title))
            guard await resolveBeforeChanging(store) else { return nil }
            await store.importPreset(result.preset)
            guard store.failure == nil else { return nil }
            store.setTitle(title, for: result.preset.name)
            if !result.skipped.isEmpty {
                let note = NSAlert()
                note.messageText = "Imported “\(title)”"
                note.informativeText = "eqtune has no equivalent for \(result.skipped.count == 1 ? "this filter" : "these filters"), so \(result.skipped.count == 1 ? "it was" : "they were") left out: \(ListFormatter.localizedString(byJoining: result.skipped))."
                note.runModal()
            }
            return result.preset.name
        } catch {
            store.failure = EqtuneStore.Failure(error)
            return nil
        }
    }

    /// Asks `request`'s question. A name with a problem asks again, saying what's wrong: a
    /// SwiftUI alert can't, since its message stays as it was when it opened.
    static func askName(_ request: NameRequest, store: EqtuneStore) async {
        let field = NSTextField(string: request.initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.note ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: request.action)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let problem = store.titleProblem(typed, own: request.own) else {
                return await request.run(typed, store: store)
            }
            alert.informativeText = problem
        }
    }

    static func exportPreset(_ name: String, store: EqtuneStore) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).toml"
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data]
        panel.message = "Share this file; anyone with Oomph or eqtune can import it."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await store.exportPreset(name, to: url)
    }
}

enum Links {
    static let repository = URL(string: "https://github.com/immdipu/oomph")!
    static let issues = URL(string: "https://github.com/immdipu/oomph/issues/new/choose")!
    static let eqtune = URL(string: "https://github.com/y7nieSEl5/eqtune")!
}

// MARK: - Naming presets

/// A question for a preset name (see `Dialogs.askName`): what it's for, and what to do with
/// the answer.
struct NameRequest {
    let title: String
    let action: String
    var initial = ""
    /// Shown under the question.
    var note: String?
    /// The preset being renamed or saved over, which may keep its name.
    var own: String?
    /// Gets the eqtune name made from what was typed.
    let perform: (String) async -> Void

    /// Does what was asked under the eqtune name made from `typed`, then remembers `typed` as
    /// the name of the preset that made.
    @MainActor func run(_ typed: String, store: EqtuneStore) async {
        let name = store.name(for: typed, own: own)
        await perform(name)
        if store.presets.contains(name) { store.setTitle(typed, for: name) }
    }

    /// Saves the edits of `preset`, the active one, as a new preset, after `first`. One of the
    /// user's own saves in place under its own name; a built-in only ever goes to a new one.
    @MainActor static func saveAs(_ preset: String, store: EqtuneStore, first: @escaping () async -> Void = {}) -> NameRequest {
        let builtIn = EqtuneStore.isBuiltIn(preset)
        return NameRequest(title: builtIn ? "Save as a New Preset" : "Save Preset As", action: "Save",
                           initial: store.copyTitle(of: preset),
                           note: builtIn ? "“\(store.displayName(preset))” is built in, so it stays as it is. Your changes go into a new preset." : nil,
                           own: builtIn ? nil : preset) {
            await first()
            await store.savePreset(preset, as: $0)
        }
    }
}
