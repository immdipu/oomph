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
                    .disabled(store.isBusy)
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
        VStack(spacing: 10) {
            EQCurveView(bands: shown?.bands ?? [], sampleRate: status.outputRateHz ?? 48_000)
                .frame(height: 64)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(status.isOn && !status.bypass ? 1 : 0.45)
                .overlay { if preset == nil { ProgressView().controlSize(.small) } }
                .animation(.oomph, value: preset?.bands)
            ForEach(Tone.allCases, id: \.self) { tone in
                toneSlider(tone, preset: preset)
            }
            if let shown, case let over = shown.overloadDB(sampleRate: status.outputRateHz ?? 48_000), over >= 0.5 {
                HStack {
                    Label("Loud parts may distort", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Fix") { Task { await store.autoPreamp() } }
                        .controlSize(.small)
                        .disabled(store.isBusy)
                        .help("Lower the preamp by \(Format.db(over).dropFirst()) so the biggest boost fits")
                }
                .font(.caption)
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
                guard !editing, let db = toneDrafts[tone] else { return }
                Task {
                    await store.setTone(tone, to: db)
                    if toneDrafts[tone] == db { toneDrafts[tone] = nil }
                }
            }
            .disabled(preset == nil)
            .accessibilityValue(Format.db(value))
            Text(Format.db(value))
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
                .disabled(store.isBusy)
            }
            .padding(.horizontal, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.presets, id: \.self) { name in
                        MenuRow {
                            Task { await store.selectPreset(name) }
                        } label: {
                            Image(systemName: "checkmark")
                                .opacity(name == status.preset ? 1 : 0)
                                .font(.caption.weight(.bold))
                            Text(displayName(name))
                            if status.dirtyPresets.contains(name) {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                                    .help("Unsaved changes")
                            }
                        }
                        .disabled(store.isBusy)
                    }
                }
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: true)
            if status.activeIsDirty {
                HStack {
                    Text("“\(displayName(status.preset))” has unsaved changes.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { Task { await Dialogs.reset(status.preset, store: store) } }
                        .controlSize(.small)
                        .disabled(store.isBusy)
                        .help(Dialogs.hasOriginal(status.preset)
                              ? "Put “\(displayName(status.preset))” back to its original tuning"
                              : "Put “\(displayName(status.preset))” back to how it was last saved")
                    Button("Save") { Task { await store.savePreset(as: status.preset) } }
                        .controlSize(.small)
                        .disabled(store.isBusy)
                }
                .font(.caption)
                .padding(.horizontal, 6)
            }
            if let device = outputs.current {
                Toggle(isOn: Binding(get: { store.devicePresets[device.id] == status.preset },
                                     set: { store.setDevicePreset($0 ? status.preset : nil, for: device.id) })) {
                    Text("Always use “\(displayName(status.preset))” on \(device.name)")
                        .lineLimit(2)
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
