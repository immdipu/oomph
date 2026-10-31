import AppKit
import SwiftUI

/// The menu bar popover: everything for everyday listening, without opening a window.
struct MenuView: View {
    @Environment(EqtuneStore.self) private var store
    @Environment(AudioOutputs.self) private var outputs
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    /// Tone slider positions not yet sent to eqtune, so the curve follows a drag.
    @State private var toneDrafts: [Tone: Double] = [:]
    /// Counts each tone's sends. Only the latest may clear the draft when eqtune answers: an
    /// earlier one, or one for a preset since switched away from, would wipe a newer value.
    @State private var toneSends: [Tone: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = store.status {
                header(status)
                Divider()
                tuning(status)
                Divider()
                presets(status)
                Divider()
                HStack(spacing: 8) {
                    HoldToCompareButton()
                    Button { open { openWindow(id: "equalizer") } } label: {
                        Label("Equalizer", systemImage: "slider.vertical.3")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                .padding(12)
            } else if let blocker = store.blocker {
                BlockerView(blocker: blocker).padding(12)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            }
            Divider()
            VStack(spacing: 0) {
                MenuRow("Settings…", shortcut: ",") { open { openSettings() } }
                    .keyboardShortcut(",")
                MenuRow("Quit Oomph", shortcut: "Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(6)
        }
        .frame(width: 320)
        // A draft belongs to the preset it was dragged on.
        .onChange(of: store.status?.preset) {
            toneDrafts = [:]
            toneSends = toneSends.mapValues { $0 + 1 }
        }
        .onAppear { store.setVisible(.menu, true) }
        .onDisappear { store.setVisible(.menu, false) }
    }

    private func open(_ show: () -> Void) {
        dismiss()
        NSApp.activate()
        show()
    }

    // MARK: - Sections

    private func header(_ status: EqtuneStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Oomph").font(.headline)
                    StatusLine(status: status, isFailing: store.isFailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BusyIndicator(isBusy: store.isBusy)
                EqtuneToggle(isOn: status.isOn, change: { await toggle($0) }) { _ in Text("Equalizer") }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(status.isOn ? "Turn the EQ off" : "Turn the EQ on")
            }
            if store.isFailing {
                Label(status.lastError ?? "The audio engine isn’t running (\(status.suspension ?? "stopped")).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = store.failure {
                FailureBanner(failure: failure) { store.failure = nil }
            }
        }
        .padding(12)
    }

    @ViewBuilder private func tuning(_ status: EqtuneStatus) -> some View {
        let preset = store.activePreset.flatMap { $0.name == status.preset ? $0 : nil }
        let shown = preset.map(withToneDrafts)
        let over = shown?.overloadDB(sampleRate: status.outputRateHz ?? 48_000) ?? 0
        VStack(spacing: 10) {
            EQCurveView(bands: shown?.bands ?? [], sampleRate: status.outputRateHz ?? 48_000)
                .frame(height: 64)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(status.isOn && !status.bypass ? 1 : 0.45)
                .overlay { if preset == nil { ProgressView().controlSize(.small) } }
                .animation(.oomph, value: preset?.bands)
                // On the curve rather than below it, so the popover doesn't grow and shrink each
                // time a Bass or Treble drag crosses the line.
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        if over >= 0.5 {
                            HStack(spacing: 6) {
                                Label("Loud parts may distort", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Button("Fix") { Task { await store.autoPreamp(of: status.preset) } }
                                    .controlSize(.small)
                                    .help("Lower the preamp by \(Format.db(over).dropFirst()) so the biggest boost fits")
                            }
                            .font(.caption)
                            .padding(.leading, 8)
                            .padding(.trailing, 3)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                            .transition(.opacity)
                        }
                    }
                    .animation(.oomph, value: over >= 0.5)
                }
            ForEach(Tone.allCases, id: \.self) { tone in
                toneSlider(tone, preset: preset)
            }
        }
        .padding(12)
    }

    private func toneSlider(_ tone: Tone, preset: Preset?) -> some View {
        let value = toneDrafts[tone] ?? preset?.toneBand(tone).db ?? 0
        return HStack(spacing: 10) {
            Text(tone.name)
                .frame(width: 46, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { toneDrafts[tone] = ($0 * 2).rounded() / 2 }), in: Tone.range) { editing in
                // The store, not `preset`: SwiftUI calls this closure as it was when the drag began.
                // Letting go where it already is sends nothing: setTone checks on eqtune's answer.
                guard !editing, let db = toneDrafts[tone], let name = store.status?.preset else { return }
                toneSends[tone, default: 0] += 1
                let send = toneSends[tone]
                Task {
                    await store.setTone(tone, to: db, of: name)
                    // A drag under way, a later release or a preset switch owns the draft otherwise.
                    if toneSends[tone] == send, toneDrafts[tone] == db { toneDrafts[tone] = nil }
                }
            }
            .disabled(preset == nil)
            .accessibilityValue(Format.db(value))
            Text(preset == nil && toneDrafts[tone] == nil ? "–" : Format.db(value)) // still reading it
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .help(tone == .bass ? "Low end: the weight and punch of the sound" : "High end: the sparkle and detail of the sound")
    }

    private func presets(_ status: EqtuneStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Presets") {
                Menu {
                    ForEach(LibraryPreset.Category.allCases, id: \.self) { category in
                        Section(category.rawValue) {
                            ForEach(SoundLibrary.presets.filter { $0.category == category }) { item in
                                Button { Task { await Dialogs.use(item, store: store) } } label: {
                                    Label(item.title, systemImage: item.symbol)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Sound Library", systemImage: "books.vertical")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.presets, id: \.self) { name in
                        MenuRow {
                            store.pick(name)
                        } label: {
                            // At once, while eqtune switches.
                            Image(systemName: "checkmark")
                                .opacity(name == (store.picked ?? status.preset) ? 1 : 0)
                                .font(.caption.weight(.bold))
                            Text(store.displayName(name))
                            if status.dirtyPresets.contains(name) {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                                    .help("Unsaved changes")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
            if status.activeIsDirty {
                HStack {
                    Text("“\(store.displayName(status.preset))” has unsaved changes.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { Task { await Dialogs.reset(status.preset, store: store) } }
                        .controlSize(.small)
                        .help(EqtuneStore.isBuiltIn(status.preset)
                              ? "Put “\(store.displayName(status.preset))” back to its original tuning"
                              : "Put “\(store.displayName(status.preset))” back to how it was last saved")
                    Button("Save") { Task { await save(status.preset) } }
                        .controlSize(.small)
                        .help(EqtuneStore.isBuiltIn(status.preset)
                              ? "“\(store.displayName(status.preset))” is built in: save these changes as a new preset"
                              : "Save these changes to “\(store.displayName(status.preset))”")
                }
                .font(.caption)
                .padding(.horizontal, 6)
            }
            if let device = outputs.current {
                Toggle(isOn: Binding(get: { store.devicePresets[device.id] == status.preset },
                                     set: { store.setDevicePreset($0 ? status.preset : nil, for: device.id) })) {
                    Text("Always use “\(store.displayName(status.preset))” on \(device.name)")
                        .lineLimit(2, reservesSpace: true) // so the rows below don't move with the name
                }
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 6)
                .help("Oomph switches to this preset whenever \(device.name) becomes the output.")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func withToneDrafts(_ preset: Preset) -> Preset {
        toneDrafts.reduce(into: preset) { preset, draft in
            preset.bands = preset.bands(settingTone: draft.key, to: draft.value)
        }
    }

    /// A built-in stays as it is: its changes can only go to a new preset.
    private func save(_ preset: String) async {
        guard EqtuneStore.isBuiltIn(preset) else { return await store.savePreset(preset) }
        await Dialogs.askName(.saveAs(preset, store: store), store: store)
    }

    private func toggle(_ on: Bool) async {
        guard !on else { return await store.setOn(true) }
        if let unsaved = await store.turnOff() { await Dialogs.resolveAfterTurningOff(unsaved, store: store) }
    }
}

/// Shown instead of the controls when there's no status to show.
private struct BlockerView: View {
    @Environment(EqtuneStore.self) private var store
    let blocker: EqtuneStore.Blocker

    var body: some View {
        switch blocker {
        case .notInstalled:
            OnboardingView(compact: true)
        case .binaryMissing:
            VStack(alignment: .leading, spacing: 8) {
                Label("The audio engine is missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text("This copy of Oomph has no bundled engine. Install eqtune with Rust’s cargo, then reopen the menu:")
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
        case .unreachable(let message):
            problem("The audio engine isn’t responding.", detail: message, canRestart: true)
        case .unreadable(let raw):
            problem("Oomph couldn’t read eqtune’s output.", raw: raw)
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
                FailureBanner(failure: EqtuneStore.Failure(EqtuneError.parseFailure(raw: raw)))
            }
            if canRestart {
                HStack {
                    Button("Restart Engine") { Task { await store.restartEngine() } }
                        .disabled(store.isBusy)
                    if store.isBusy { ProgressView().controlSize(.small) }
                }
            }
            if let failure = store.failure {
                FailureBanner(failure: failure) { store.failure = nil }
            }
        }
    }
}

#Preview {
    MenuView()
        .environment(EqtuneStore(client: MockEqtuneClient()))
        .environment(AudioOutputs())
}
