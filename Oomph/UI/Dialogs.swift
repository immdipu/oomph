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
        switch ask("Save your changes?", "The EQ is off. \(list(presets)) \(verb) unsaved changes.") {
        case .save: await store.saveEditsAndTurnOff()
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
        switch ask("Save your changes first?", "\(list(dirty)) \(verb) unsaved changes. Save or discard them to continue.") {
        case .save: await store.saveAll()
        case .discard: await store.discardAll()
        case .cancel: return false
        }
        return !store.hasUnsavedEdits && store.failure == nil
    }

    // MARK: - Going back

    /// Puts `preset` back to its original state, after asking: the tuning it shipped with, or
    /// for one of the user's own, how it was last saved.
    static func reset(_ preset: String, store: EqtuneStore) async {
        if hasOriginal(preset) { await resetToOriginal(preset, store: store) } else { await resetToSaved(store: store) }
    }

    /// Whether Reset has anything to put back for `preset`.
    static func canReset(_ preset: String, store: EqtuneStore) -> Bool {
        hasOriginal(preset) || store.status?.dirtyPresets.contains(preset) == true
    }

    /// eqtune's own presets and Oomph's library ones have an original tuning to go back to.
    static func hasOriginal(_ preset: String) -> Bool {
        EqtuneStore.shippedPresets.contains(preset) || SoundLibrary.preset(preset) != nil
    }

    /// Throws away unsaved edits, after asking. eqtune can only discard every preset's edits
    /// at once (by restarting the EQ), so the question names everything that goes back.
    private static func resetToSaved(store: EqtuneStore) async {
        guard let status = store.status, !status.dirtyPresets.isEmpty else { return }
        let one = status.dirtyPresets.count == 1
        let alert = NSAlert()
        alert.messageText = "Reset to the last saved version?"
        alert.informativeText = "\(list(status.dirtyPresets)) \(one ? "goes" : "go") back to how \(one ? "it was" : "they were") last saved."
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
        alert.messageText = "Reset “\(displayName(preset))” to its original tuning?"
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

    private static func list(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names.map { "“\(displayName($0))”" })
    }

    // MARK: - Files

    /// Asks for an eqtune preset or an Equalizer APO / AutoEq file, imports it under a free
    /// name, and says which filters it couldn't use.
    static func importPreset(store: EqtuneStore) async {
        let panel = NSOpenPanel()
        panel.message = "Choose an Oomph or eqtune preset (.toml), or a parametric EQ file from AutoEq or Equalizer APO (.txt)."
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data, .plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = try PresetImport.read(text, name: store.availableName(PresetImport.suggestedName(for: url)))
            guard await resolveBeforeChanging(store) else { return }
            await store.importPreset(result.preset)
            guard store.failure == nil, !result.skipped.isEmpty else { return }
            let note = NSAlert()
            note.messageText = "Imported “\(result.preset.name)”"
            note.informativeText = "eqtune has no equivalent for \(result.skipped.count == 1 ? "this filter" : "these filters"), so \(result.skipped.count == 1 ? "it was" : "they were") left out: \(ListFormatter.localizedString(byJoining: result.skipped))."
            note.runModal()
        } catch {
            store.failure = EqtuneStore.Failure(error)
        }
    }

    /// Explains where headphone corrections come from before asking for the file.
    static func importHeadphoneCorrection(store: EqtuneStore) async {
        let alert = NSAlert()
        alert.messageText = "Import a headphone correction"
        alert.informativeText = """
            AutoEq has measured corrections for thousands of headphones and earbuds. \
            They flatten each model's quirks, so music sounds the way it was mixed.

            1. On autoeq.app, pick your headphones.
            2. Choose the “Equalizer APO” parametric EQ and download it.
            3. Import the downloaded file here.
            """
        alert.addButton(withTitle: "Choose File…")
        alert.addButton(withTitle: "Open autoeq.app")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: await importPreset(store: store)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(Links.autoEQ)
        default: break
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
    static let autoEQ = URL(string: "https://autoeq.app")!
}

// MARK: - Naming presets

/// A question for a preset name: what it's for, and what to do with the answer.
struct NameRequest: Identifiable {
    let id = UUID()
    let title: String
    let action: String
    var initial = ""
    /// Saving under the active preset's own name saves it in place.
    var allowActive = false
    let perform: (String) async -> Void
}

extension View {
    /// Shows `request` as an alert with a name field, checked against eqtune's naming rules.
    func namePrompt(_ request: Binding<NameRequest?>) -> some View {
        modifier(NamePromptModifier(request: request))
    }
}

private struct NamePromptModifier: ViewModifier {
    @Environment(EqtuneStore.self) private var store
    @Binding var request: NameRequest?
    @State private var name = ""

    func body(content: Content) -> some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let problem = request.flatMap { store.nameProblem(trimmed, allowActive: $0.allowActive) }
        content
            .alert(request?.title ?? "", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                   presenting: request) { request in
                TextField("Name", text: $name)
                Button(request.action) { Task { await request.perform(trimmed) } }
                    .disabled(problem != nil)
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(problem ?? "Letters, digits, “-”, “_” and “.” only.")
            }
            .onChange(of: request?.id) { name = request?.initial ?? "" }
    }
}
