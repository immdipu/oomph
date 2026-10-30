import SwiftUI

/// The equalizer window: presets on the left, the active preset's curve and bands on the
/// right. Every change goes straight to eqtune; the window shows what eqtune reports back.
struct EqualizerView: View {
    @Environment(EqtuneStore.self) private var store

    var body: some View {
        NavigationSplitView {
            PresetSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .animation(.oomph, value: store.activePreset == nil)
        }
        .frame(minWidth: 940, minHeight: 640)
        .onAppear { store.setVisible(.editor, true) }
        .onDisappear { store.setVisible(.editor, false) }
    }

    @ViewBuilder private var detail: some View {
        if let status = store.status, let preset = store.activePreset, preset.name == status.preset {
            PresetEditor(status: status, preset: preset)
        } else if store.blocker != nil {
            ContentUnavailableView("Can’t reach the audio engine", systemImage: "exclamationmark.triangle",
                                   description: Text("Open the Oomph menu in the menu bar for details."))
        } else if let problem = store.presetProblem {
            ContentUnavailableView {
                Label("Can’t read this preset", systemImage: "exclamationmark.triangle")
            } description: {
                Text(problem.message)
            } actions: {
                if let raw = problem.raw {
                    DisclosureGroup("eqtune output") {
                        Text(raw).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    .frame(maxWidth: 420)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Edits the active preset. Drags and typing show up instantly as drafts; eqtune gets the
/// change on release or after a short pause, and its answer replaces the draft.
private struct PresetEditor: View {
    @Environment(EqtuneStore.self) private var store
    let status: EqtuneStatus
    let preset: Preset
    /// Unsent edits, keyed by the frequency eqtune knows each band by.
    @State private var drafts: [Double: Band] = [:]
    @State private var pending: [Double: Task<Void, Never>] = [:]
    /// The selected band's frequency as eqtune has it, per preset: when another preset
    /// arrives, the old selection can't pick out its band at the same frequency.
    @State private var selections: [String: Double] = [:]
    /// The graph's ±dB scale: nil picks 12 or 24 to fit the curve.
    @State private var wideScale: Bool?
    @State private var nameRequest: NameRequest?

    private var shown: [Band] { preset.bands.map { drafts[$0.hz] ?? $0 } }
    private var sampleRate: Double { status.outputRateHz ?? 48_000 }
    private var selection: Double? {
        get { selections[preset.name] }
        nonmutating set { selections[preset.name] = newValue }
    }
    /// The selected band's frequency as eqtune has it. A moved band's new frequency can
    /// arrive from eqtune a moment before `selection` follows it; its draft bridges that.
    private var selectedHz: Double? {
        guard let selection else { return nil }
        if preset.bands.contains(where: { $0.hz == selection }) { return selection }
        return drafts[selection].flatMap { draft in preset.bands.first { $0.sitsAt(draft.hz) }?.hz }
    }
    private var selectedIndex: Int? { preset.bands.firstIndex { $0.hz == selectedHz } }
    private var range: Double {
        let needsWide = preset.bands.contains { abs($0.db) > 12 } || preset.bands.peakGainDB(sampleRate: sampleRate) > 12
        return (wideScale ?? needsWide) ? 24 : 12
    }

    var body: some View {
        VStack(spacing: 0) {
            if !status.isOn {
                HStack {
                    Label("The EQ is off, so you’re hearing your Mac’s original sound. Changes still save to this preset.",
                          systemImage: "power")
                    Spacer()
                    Button("Turn On") { Task { await store.setOn(true) } }
                        .disabled(store.isBusy)
                }
                .font(.callout)
                .padding(10)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top])
            }
            if let failure = store.failure {
                FailureBanner(failure: failure) { store.failure = nil }
                    .padding([.horizontal, .top])
            }
            VStack(alignment: .leading, spacing: 8) {
                EQGraph(bands: preset.bands, shown: shown, sampleRate: sampleRate, range: range,
                        selection: Binding(get: { selectedHz }, set: { selection = $0 }),
                        onEdit: edit, onAdd: add, onRemove: remove)
                    .frame(minHeight: 260)
                HStack {
                    Text("Drag a point to shape the sound · Double-click to add a band · Scroll to change a band’s width · Hold ⇧ to change only the gain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 12)
                    // Only a scale picked here animates: one that flips to fit eqtune's answer comes with
                    // re-sorted bands, and points would slide across each other.
                    Picker("Scale", selection: Binding(get: { range }, set: { scale in withAnimation(.oomph) { wideScale = scale == 24 } })) {
                        Text("±12 dB").tag(12.0)
                        Text("±24 dB").tag(24.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding()
            Divider()
            BandStrip(bands: shown, selected: selectedIndex, canAdd: preset.bands.count < Limits.maxBands,
                      onSelect: { selection = preset.bands[$0].hz }, onAdd: addInGap)
            Divider()
            Group {
                if let index = selectedIndex {
                    BandInspector(index: index, band: shown[index],
                                  onEdit: { edit(preset.bands[index], $0, $1) },
                                  onRemove: { remove(preset.bands[index]) })
                } else {
                    FrequencyGuide(hint: preset.bands.isEmpty
                                   ? "This preset is flat. Double-click the graph or use Add Band to start shaping the sound."
                                   : "Select a band to fine-tune it, or double-click the graph to add one.")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(height: 150, alignment: .top)
            Divider()
            OutputBar(status: status, preset: preset, bands: shown)
        }
        // Another preset morphs the curve and slides the points to their new places. Edits
        // don't: a drag follows the pointer, and eqtune's answer to it matches what's shown.
        .animation(.oomph, value: preset.name)
        .animation(.oomph, value: selection)
        .animation(.oomph, value: status.isOn)
        .animation(.oomph, value: store.failure)
        .navigationTitle(displayName(preset.name))
        .navigationSubtitle(status.activeIsDirty ? "Edited" : "Saved")
        .toolbar { toolbar }
        .namePrompt($nameRequest)
        .onChange(of: preset.name) {
            pending.values.forEach { $0.cancel() }
            pending = [:]
            drafts = [:]
            selections = [:]
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.undo() } }
                .disabled(!store.canUndo || store.isBusy)
                .keyboardShortcut("z")
                .help("Undo the last change to this preset (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { Task { await store.redo() } }
                .disabled(!store.canRedo || store.isBusy)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
        }
        ToolbarItem {
            HoldToCompareButton(inToolbar: true)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Revert to Saved Version…") { Task { await Dialogs.revert(store: store) } }
                    .disabled(!status.activeIsDirty)
                Button("Reset to Original Tuning…") { Task { await Dialogs.resetToOriginal(preset.name, store: store) } }
                    .disabled(!Dialogs.hasOriginal(preset.name))
            } label: {
                toolbarTitle("Revert")
            }
            .disabled(store.isBusy || !(status.activeIsDirty || Dialogs.hasOriginal(preset.name)))
            .help("Go back to the last saved version, or to the preset’s original tuning")
            Button { Task { await store.savePreset(as: preset.name) } } label: { toolbarTitle("Save") }
                .disabled(!status.activeIsDirty || store.isBusy)
                .keyboardShortcut("s")
                .help("Save these changes to “\(displayName(preset.name))” (⌘S)")
            Button {
                nameRequest = NameRequest(title: "Save Preset As", action: "Save",
                                          initial: store.availableName("\(preset.name)-copy"), allowActive: true) {
                    await store.savePreset(as: $0)
                }
            } label: {
                toolbarTitle("Save As…")
            }
            .disabled(store.isBusy)
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Save this tuning as a new preset (⇧⌘S)")
            EqtuneToggle(isOn: status.isOn, change: { await toggle($0) }) { on in
                Label(on ? "EQ On" : "EQ Off", systemImage: "power")
            }
            .toggleStyle(.button)
            .disabled(store.isBusy)
            .help(status.isOn ? "Turn the EQ off" : "Turn the EQ on")
        }
    }

    /// A text button's title, with room on both sides inside its toolbar glass.
    private func toolbarTitle(_ title: String) -> some View {
        Text(title).padding(.horizontal, 6)
    }

    private func toggle(_ on: Bool) async {
        guard !on else { return await store.setOn(true) }
        if let unsaved = await store.turnOff() { await Dialogs.resolveAfterTurningOff(unsaved, store: store) }
    }

    // MARK: - Edits

    private func edit(_ original: Band, _ edited: Band, _ timing: EditTiming) {
        // A typed value or a new band type morphs; drags, scrolling and arrow keys follow at once.
        withAnimation(timing == .now ? .oomph : nil) { drafts[original.hz] = edited }
        pending[original.hz]?.cancel()
        guard timing != .live else { return }
        let name = preset.name
        pending[original.hz] = Task {
            if timing == .soon { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            if edited != original { await store.editBand(original, of: name, to: edited) }
            guard drafts[original.hz] == edited else { return } // edited again meanwhile
            // eqtune shows its answer by now. A band still at the old frequency but not as edited
            // means eqtune refused the edit: it glides back. Otherwise this changes nothing.
            let unmoved = store.activePreset?.bands.first { $0.sitsAt(original.hz) }
            withAnimation(unmoved.map { $0 != edited } == true ? .oomph : nil) { drafts[original.hz] = nil }
            // A frequency change moves the band; keep it selected at its new frequency. It's the
            // same band, so nothing animates.
            if unmoved == nil, selection == original.hz,
               let moved = store.activePreset?.bands.first(where: { $0.sitsAt(edited.hz) }) {
                withTransaction(\.disablesAnimations, true) { selection = moved.hz }
            }
        }
    }

    private func add(_ band: Band) {
        Task {
            await store.addBand(band)
            if store.failure == nil { selection = store.activePreset?.bands.first { $0.sitsAt(band.hz) }?.hz }
        }
    }

    /// Adds a flat band in the middle of the widest stretch of spectrum without one.
    private func addInGap() {
        let edges = ([20.0] + preset.bands.map(\.hz) + [20_000]).map(log10).sorted()
        let gap = zip(edges, edges.dropFirst()).max { $0.1 - $0.0 < $1.1 - $1.0 } ?? (log10(20), log10(20_000))
        let hz = pow(10, (gap.0 + gap.1) / 2)
        add(Band(kind: .peaking, hz: preset.freeFrequency(near: hz < 1000 ? hz.rounded() : (hz / 10).rounded() * 10), db: 0, q: 1))
    }

    private func remove(_ band: Band) {
        if selection == band.hz { selection = nil }
        Task { await store.editBand(band, of: preset.name, to: nil) }
    }
}
