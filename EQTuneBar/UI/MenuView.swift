import AppKit
import SwiftUI

/// The menu bar popover.
struct MenuView: View {
    @Environment(EqtuneStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = store.status {
                controls(status)
            } else if let blocker = store.blocker {
                BlockerView(blocker: blocker)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            Divider().padding(.vertical, 6)
            if store.status != nil {
                MenuRow("Edit bands…") {
                    dismiss()
                    NSApp.activate()
                    openWindow(id: "band-editor")
                }
            }
            MenuRow("Settings…", shortcut: ",") {
                dismiss()
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            MenuRow("Quit Oomph", shortcut: "Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 290)
        .onAppear { store.setVisible(.menu, true) }
        .onDisappear { store.setVisible(.menu, false) }
    }

    @ViewBuilder private func controls(_ status: EqtuneStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("EQ").font(.headline)
                Spacer()
                if store.isBusy { ProgressView().controlSize(.small) }
                Toggle("EQ", isOn: Binding(get: { status.isOn }, set: { on in Task { await toggle(on) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(store.isBusy)
            }
            Text(Self.outputLine(status))
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.isFailing {
                Label(status.lastError ?? "The engine isn't running (\(status.suspension ?? "stopped")).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let paused = Self.pausedReason(status) {
                Text(paused).font(.caption).foregroundStyle(.secondary)
            }
            if let failure = store.failure {
                Label(failure.message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)

        Divider().padding(.vertical, 6)
        VStack(alignment: .leading, spacing: 4) {
            Text("Preset").font(.caption).foregroundStyle(.secondary)
            Picker("Preset", selection: Binding(get: { status.preset },
                                                set: { name in Task { await store.selectPreset(name) } })) {
                ForEach(store.presets, id: \.self) { name in
                    Text(status.dirtyPresets.contains(name) ? "\(name) (edited)" : name).tag(name)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(store.isBusy)
        }
        .padding(.horizontal, 6)

        Divider().padding(.vertical, 6)
        VStack(spacing: 6) {
            HStack {
                Text("Bypass (A/B)")
                Spacer()
                Toggle("Bypass (A/B)", isOn: Binding(get: { status.bypass },
                                                     set: { on in Task { await store.setBypass(on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(store.isBusy)
            }
            HStack {
                Text("Preamp")
                Spacer()
                Text(Self.decibels(status.preampDB))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
    }

    static func decibels(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always(includingZero: false))) + " dB"
    }

    private func toggle(_ on: Bool) async {
        guard !on else { return await store.setOn(true) }
        var unsaved = await store.turnOff()
        while let presets = unsaved {
            unsaved = await UnsavedEditsAlert.resolve(presets, store: store)
        }
    }

    static func outputLine(_ status: EqtuneStatus) -> String {
        let name = status.outputName ?? "No output device"
        guard let rate = status.outputRateHz else { return name }
        return "\(name) · \((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }

    /// Auto-off paused the engine on purpose; not a problem.
    static func pausedReason(_ status: EqtuneStatus) -> String? {
        guard status.isOn, !status.engineRunning else { return nil }
        switch status.suspension {
        case "idle": return "Paused until audio plays."
        case "low-power": return "Paused in Low Power Mode."
        default: return nil
        }
    }
}

/// Shown instead of the controls when there's no status to show.
private struct BlockerView: View {
    @Environment(EqtuneStore.self) private var store
    let blocker: EqtuneStore.Blocker

    var body: some View {
        switch blocker {
        case .notInstalled:
            OnboardingView().frame(maxWidth: .infinity)
        case .binaryMissing:
            VStack(alignment: .leading, spacing: 8) {
                Label("The eqtune engine is missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text("This copy of Oomph has no bundled engine. Install eqtune with Rust's cargo, then reopen the menu:")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Self.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    }
                }
            }
            .padding(6)
        case .unreachable(let message):
            problem("The audio engine isn't responding.", detail: message, canRestart: true)
        case .unreadable(let raw):
            problem("Oomph couldn't read eqtune's output.", raw: raw)
        }
    }

    static let installCommand = "cargo install --locked eqtune && eqtune install"

    private func problem(_ title: String, detail: String? = nil, raw: String? = nil, canRestart: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill").font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let raw {
                DisclosureGroup("eqtune output") {
                    ScrollView {
                        Text(raw)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.caption)
            }
            if canRestart {
                HStack {
                    Button("Restart engine") { Task { await store.restartEngine() } }
                        .disabled(store.isBusy)
                    if store.isBusy { ProgressView().controlSize(.small) }
                }
            }
            if let failure = store.failure {
                Text(failure.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
    }
}

/// A full-width, menu-style row button that highlights on hover.
struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text("⌘\(shortcut)").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(hovering ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `eqtune off` stops at a save/discard question when presets have unsaved edits. By then
/// the EQ is already off; this asks the same question in a native alert.
@MainActor
enum UnsavedEditsAlert {
    /// Returns presets that still have unsaved edits afterwards (saving keeps only the
    /// active preset's edits), or nil when nothing is left to ask about.
    static func resolve(_ presets: [String], store: EqtuneStore) async -> [String]? {
        let active = store.status?.preset
        // "Save as…" saves the active preset's tuning, so it only helps if that one has edits.
        let canSave = active.map(presets.contains) ?? false
        let alert = NSAlert()
        alert.messageText = "Unsaved band edits"
        alert.informativeText = "The EQ is off. \(ListFormatter.localizedString(byJoining: presets)) \(presets.count == 1 ? "has" : "have") unsaved changes."
        let titles = (canSave ? ["Save as…"] : []) + ["Discard", "Cancel"]
        titles.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch titles[index] {
        case "Save as…":
            guard let name = askName(store: store) else { return nil }
            let remaining = await store.saveEditsAndTurnOff(as: name)
            if let failure = store.failure {
                // The popover may be closed by now, so say it here and ask again.
                let error = NSAlert()
                error.messageText = "Couldn't save the edits"
                error.informativeText = failure.message
                error.runModal()
                return presets
            }
            return remaining
        case "Discard":
            await store.discardEditsAndTurnOff()
            return nil
        default:
            return nil
        }
    }

    /// Asks for a preset name until it's one eqtune will take, or the user cancels. Saving
    /// under the active preset's own name saves it in place.
    static func askName(store: EqtuneStore) -> String? {
        let base = "\((store.status?.preset).map { "\($0)-" } ?? "")edited"
        let suggestion = ([base] + (2...99).map { "\(base)-\($0)" }).first { !store.presets.contains($0) } ?? base
        let alert = NSAlert()
        alert.messageText = "Save edits as a preset"
        alert.informativeText = "Use letters, digits, “-”, “_” or “.”."
        let field = NSTextField(string: suggestion)
        field.frame.size.width = 240
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let problem = store.nameProblem(name, allowActive: true) else { return name }
            alert.informativeText = problem
        }
        return nil
    }
}

/// The menu bar icon: the slider symbol, knocked out of a filled rounded square when the
/// EQ is on, with a red dot when something needs attention.
struct MenuBarLabel: View {
    let store: EqtuneStore

    var body: some View {
        let on = store.status?.isOn == true
        // eqtune's `last error` sticks around after the engine recovers, so the dot follows
        // whether there is a problem now.
        let alert = store.isFailing || store.blocker != nil
        Image(nsImage: Self.icon(on: on, alert: alert))
            .accessibilityLabel("Oomph, EQ \(on ? "on" : "off")\(alert ? ", needs attention" : "")")
    }

    static func icon(on: Bool, alert: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: on ? 10 : 13, weight: on ? .bold : .medium)
        guard let symbol = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSImage() }
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: false) { rect in
            // A template image only needs alpha; the red dot makes it a color image, which
            // then needs the menu bar's own text color (resolved here, at draw time).
            let ink = alert ? NSColor.labelColor : .black
            let glyph = NSRect(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height)
            if on {
                ink.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0.5), xRadius: 4, yRadius: 4).fill()
                symbol.draw(in: glyph, from: .zero, operation: .destinationOut, fraction: 1)
            } else {
                symbol.draw(in: glyph)
                ink.setFill()
                rect.fill(using: .sourceAtop)
            }
            if alert {
                let dot = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill(using: .clear)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = !alert
        return image
    }
}

private extension NSBezierPath {
    /// Fills with a compositing operation (used to punch a gap around the error dot).
    func fill(using operation: NSCompositingOperation) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = operation
        fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

#Preview {
    MenuView().environment(EqtuneStore(client: MockEqtuneClient()))
}
