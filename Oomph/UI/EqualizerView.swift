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
    /// Unsent edits, keyed by the frequency eqtune has each band at, or will have once the
    /// edits on their way land (see `key`).
    @State private var drafts: [Double: Band] = [:]
    /// Each band's latest send, keyed like `drafts`: waiting for a pause, or for eqtune's answer.
    @State private var pending: [Double: Task<Void, Never>] = [:]
    /// Where sends moved bands: the frequency eqtune had → the new one. Until eqtune's answer
    /// arrives the band still sits at the old one, and so do points and keys built before it.
    @State private var moves: [Double: Double] = [:]
    /// Bands as last sent, keyed like `drafts`, until eqtune answers: what eqtune will have
    /// when a band's next edit takes its turn.
    @State private var sent: [Double: Band] = [:]
    /// The selected band, keyed like `drafts`, per preset: when another preset arrives, the
    /// old selection can't pick out its band at the same frequency.
    @State private var selections: [String: Double] = [:]
    /// Counts picks of another band, which gets the inspector afresh. The selected band
    /// re-sorting past another as it moves doesn't, so typing or dragging there carries on.
    @State private var picks = 0
    /// A field holds typed text it hasn't sent yet.
    @State private var typing = false
    @State private var resetting = false
    /// The graph's ±dB scale: nil picks 12 or 24 to fit the curve.
    @State private var wideScale: Bool?
    /// The automatic pick for the open preset, made when it opened. After that it only ever
    /// widens, so a release near 12 dB can't flip the graph back and forth.
    @State private var autoScale: (preset: String, wide: Bool)?
    @FocusState private var graphFocused: Bool

    private var shown: [Band] { preset.bands.map { drafts[key($0.hz)] ?? $0 } }
    private var sampleRate: Double { status.outputRateHz ?? 48_000 }
    private var selection: Double? {
        get { selections[preset.name] }
        nonmutating set { selections[preset.name] = newValue }
    }
    private var selectedIndex: Int? { preset.bands.firstIndex { key($0.hz) == selection } }
    private var range: Double {
        let auto = autoScale.flatMap { $0.preset == preset.name ? $0.wide : nil } ?? needsWide
        return (wideScale ?? auto) ? 24 : 12
    }
    /// A band or the curve goes past ±12 dB, boosts or cuts. The margin keeps a peak dragged
    /// to exactly 12 dB from counting through rounding.
    private var needsWide: Bool {
        let points = (CurveLevels.frequencies + preset.bands.map(\.hz)).filter { $0 < sampleRate / 2 }
        return preset.bands.contains { abs($0.db) > 12 }
            || preset.bands.curve(at: points, sampleRate: sampleRate).contains { abs($0) > 12.05 }
    }

    /// What the editor calls the band eqtune has at `hz`: where a send moved it, if one did.
    private func key(_ hz: Double) -> Double { moves[hz] ?? hz }

    /// The band known by `key` as eqtune will have it once the sends on their way land.
    private func band(at key: Double) -> Band? {
        sent[key] ?? store.activePreset.flatMap { $0.name == preset.name ? $0.bands.first { self.key($0.hz) == key } : nil }
    }

    /// Selects the band known by `key`, or none.
    private func select(_ key: Double?) {
        if key != selection { picks += 1 }
        selection = key
    }

    var body: some View {
        VStack(spacing: 0) {
            if !status.isOn {
                HStack {
                    Label("The EQ is off, so you’re hearing your Mac’s original sound. Changes still save to this preset.",
                          systemImage: "power")
                    Spacer()
                    Button("Turn On") { Task { await store.setOn(true) } }
                }
                .font(.callout)
                .padding(10)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top])
            }
            VStack(alignment: .leading, spacing: 8) {
                EQGraph(preset: preset.name, bands: preset.bands, shown: shown, sampleRate: sampleRate, range: range,
                        selection: Binding(get: { selectedIndex.map { preset.bands[$0].hz } }, set: { select($0.map(key)) }),
                        focused: $graphFocused, onEdit: edit, onAdjust: adjust, onAdd: add, onRemove: remove)
                    .frame(minHeight: 260)
                HStack {
                    // A failure takes the hint's place, in a row whose height the Scale picker
                    // sets: nothing moves, and nothing on the graph is covered.
                    Group {
                        if let failure = store.failure {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.octagon.fill")
                                    .foregroundStyle(.red)
                                Text(failure.message)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(failure.raw ?? failure.message)
                                Button("Dismiss", systemImage: "xmark") { store.failure = nil }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Drag a point to shape the sound · Double-click to add a band · Scroll to change a band’s width · Hold ⇧ to change only the gain")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.caption)
                    .transition(.opacity)
                    .animation(.oomph, value: store.failure)
                    Spacer(minLength: 12)
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
            // Selecting a band animates the strip and the panel below, never the graph: a drag
            // selects the point it picks up, which must follow the pointer from the first move.
            BandStrip(bands: shown, selected: selectedIndex, canAdd: preset.bands.count < Limits.maxBands,
                      onSelect: { select(key(preset.bands[$0].hz)); graphFocused = true }, onAdd: addInGap)
                .animation(.oomph, value: selection)
            Divider()
            Group {
                if let index = selectedIndex {
                    BandInspector(index: index, band: shown[index],
                                  onEdit: { edit(preset.bands[index], $0, $1) },
                                  onRemove: { remove(preset.bands[index]) })
                        .id(picks) // another band gets fresh fields, not this one's half-typed text
                } else {
                    FrequencyGuide(hint: preset.bands.isEmpty
                                   ? "This preset is flat. Double-click the graph or use Add Band to start shaping the sound."
                                   : "Select a band to fine-tune it, or double-click the graph to add one.")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(height: 150, alignment: .top)
            .animation(.oomph, value: selection)
            Divider()
            OutputBar(status: status, preset: preset, bands: shown)
        }
        // Another preset morphs the curve and slides the points to their new places. Edits
        // don't: a drag follows the pointer, and eqtune's answer to it matches what's shown.
        .animation(.oomph, value: preset.name)
        .animation(.oomph, value: status.isOn)
        .navigationTitle(store.displayName(preset.name))
        .navigationSubtitle(status.activeIsDirty ? "Edited" : EqtuneStore.isBuiltIn(preset.name) ? "Built in" : "Saved")
        .toolbar { toolbar }
        .onAppear { autoScale = (preset.name, needsWide) }
        .onChange(of: preset.name) {
            pending.values.forEach { $0.cancel() }
            pending = [:]
            drafts = [:]
            moves = [:]
            sent = [:]
            selections = [:]
            autoScale = (preset.name, needsWide)
        }
        // After eqtune's answer is drawn, so the points only move up or down.
        .onChange(of: needsWide) { if needsWide { withAnimation(.oomph) { autoScale = (preset.name, true) } } }
        .onChange(of: preset.bands) { pruneMoves() }
        .onPreferenceChange(UnsentTypingKey.self) { typing = $0 }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // None of these wait for a command to finish: eqtune runs them in order after it.
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.undo(of: preset.name) } }
                .disabled(!store.canUndo)
                .keyboardShortcut("z")
                .help("Undo the last change to this preset (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { Task { await store.redo(of: preset.name) } }
                .disabled(!store.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
        }
        ToolbarItem {
            HoldToCompareButton(inToolbar: true)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                // Once: its question waits for the edits on their way, and a second click meanwhile
                // would ask again with what's on screen before the reset.
                guard !resetting else { return }
                resetting = true
                Task {
                    await sendEdits()
                    await Dialogs.reset(preset.name, store: store)
                    resetting = false
                }
            } label: {
                toolbarTitle("Reset")
            }
            .disabled(resetting || !Dialogs.canReset(preset.name, store: store))
                .help(EqtuneStore.isBuiltIn(preset.name) ? "Put this preset back to its original tuning"
                                                       : "Put this preset back to how it was last saved")
            Button {
                // A built-in stays as it is: its changes can only go to a new preset.
                if EqtuneStore.isBuiltIn(preset.name) { return saveAs() }
                Task { await sendEdits(); await store.savePreset(preset.name) }
            } label: {
                toolbarTitle("Save")
            }
            .disabled(!status.activeIsDirty && drafts.isEmpty && !typing)
            .keyboardShortcut("s")
            .help(EqtuneStore.isBuiltIn(preset.name)
                  ? "“\(store.displayName(preset.name))” is built in: save these changes as a new preset (⌘S)"
                  : "Save these changes to “\(store.displayName(preset.name))” (⌘S)")
            Button(action: saveAs) { toolbarTitle("Save As…") }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Save this tuning as a new preset (⇧⌘S)")
            EqtuneToggle(isOn: status.isOn, change: { await toggle($0) }) { on in
                Label(on ? "EQ On" : "EQ Off", systemImage: "power")
            }
            .toggleStyle(.button)
            .help(status.isOn ? "Turn the EQ off" : "Turn the EQ on")
        }
    }

    /// A text button's title, with room on both sides inside its toolbar glass.
    private func toolbarTitle(_ title: String) -> some View {
        Text(title).padding(.horizontal, 6)
    }

    private func saveAs() {
        endTyping() // before the prompt takes the keyboard
        Task { await Dialogs.askName(.saveAs(preset.name, store: store, first: sendEdits), store: store) }
    }

    private func toggle(_ on: Bool) async {
        guard !on else { return await store.setOn(true) }
        if let unsaved = await store.turnOff() { await Dialogs.resolveAfterTurningOff(unsaved, store: store) }
    }

    // MARK: - Edits

    private func edit(_ original: Band, _ edited: Band, _ timing: EditTiming) {
        let key = key(original.hz)
        // Changes nothing and replaces no draft (a press that hasn't moved yet, a step at a
        // limit): nothing to show or send, and Save doesn't light up for it.
        if drafts[key] == nil, edited == band(at: key) { return }
        // A typed value or a new band type morphs; drags, scrolling and arrow keys follow at once.
        withAnimation(timing == .now ? .oomph : nil) { drafts[key] = edited }
        pending[key]?.cancel() // still waiting for its pause: this edit replaces it
        guard timing != .live else { return }
        // What eqtune will have when this edit's turn comes. The edit changes what differs from
        // that and leaves the rest as eqtune has it by then (after an Undo, say).
        let base = band(at: key)
        pending[key] = Task {
            if timing == .soon { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await send(edited, from: self.key(key), over: base)
        }
    }

    /// Sends one band's edit, then shows eqtune's answer in place of the draft. eqtune runs
    /// commands in the order they're sent, so a band's edits land in order, each on the last.
    private func send(_ edited: Band, from key: Double, over base: Band?) async {
        let name = preset.name
        guard let base, store.activePreset?.name == name else {
            if drafts[key] == edited { withAnimation(.oomph) { drafts[key] = nil } } // the band is gone
            return
        }
        var key = key, moved = false, refusalExpected = false
        if edited != base {
            // A move: from here on the band goes by its new frequency. eqtune refuses one onto a
            // frequency another band has or is moving to, and the band stays as it is, so the
            // next edit must still find it there rather than at the other band's frequency.
            let others = (store.activePreset?.bands ?? []).map { self.key($0.hz) }.filter { $0 != key }
            let inPlace = base.sitsAt(edited.hz), free = !others.contains { abs($0 - edited.hz) < 0.5 }
            moved = !inPlace && free
            refusalExpected = !inPlace && !free
            if moved {
                rekey(key, to: edited.hz)
                key = edited.hz
            }
            if !refusalExpected { sent[key] = edited }
            await store.editBand(base, of: name, to: edited)
            if sent[key] == edited { sent[key] = nil }
            pruneMoves()
        } else if sent[key] != nil {
            return // nothing new for eqtune: the answer to the send on its way clears the draft
        }
        guard let answered = store.activePreset.flatMap({ $0.name == name ? $0.bands : nil }) else { return }
        var answer: Band?
        if self.key(key) == key {
            // Nothing re-keyed the band meanwhile, so eqtune's answer settles where it is: where
            // this sent it; where it was, if this move failed; or, if a refusal was expected,
            // where it went after all, the band there having been removed first.
            answer = answered.first { $0.sitsAt(key) }
                ?? (moved ? answered.first { $0.sitsAt(base.hz) } : nil)
                ?? (refusalExpected ? answered.first { $0.sitsAt(edited.hz) && $0 == edited } : nil)
            if let answer, answer.hz != key {
                rekey(key, to: answer.hz)
                key = answer.hz
            }
        } else {
            // A later send moved the band on, or an earlier one's failed move took it back:
            // that send has it now. This edit's draft, if it's still the latest, followed it.
            key = self.key(key)
        }
        guard drafts[key] == edited else { return } // edited again meanwhile: that edit's send follows
        // A band not as edited means eqtune refused the edit: it glides back. Otherwise this
        // changes nothing.
        withAnimation(answer != edited ? .oomph : nil) { drafts[key] = nil }
    }

    /// From now on the band at `old` goes by `new`: its draft, its next send, the selection,
    /// and points and keys that still name it by `old`. It's the same band, so nothing animates.
    private func rekey(_ old: Double, to new: Double) {
        drafts[new] = drafts.removeValue(forKey: old)
        pending[new] = pending.removeValue(forKey: old)
        for (from, to) in moves where to == old { moves[from] = new }
        moves[old] = new
        moves[new] = nil
        if selection == old { withTransaction(\.disablesAnimations, true) { selection = new } }
    }

    /// Forgets moves that no longer apply: a band back at a frequency one moved away from (an
    /// Undo, a new band there) is that band, unless the move is still on its way. A band an
    /// Undo put back keeps its other old names and stays selected.
    private func pruneMoves() {
        guard let bands = store.activePreset.flatMap({ $0.name == preset.name ? $0.bands : nil }) else { return }
        for (old, new) in moves where sent[new] == nil && bands.contains(where: { $0.sitsAt(old) }) {
            moves[old] = nil
            guard !bands.contains(where: { $0.sitsAt(new) }) else { continue } // a new band at `old`
            for (from, to) in moves where to == new { moves[from] = old }
            if selection == new { withTransaction(\.disablesAnimations, true) { selection = old } }
        }
    }

    /// A step from wherever the band is now, its unsent edit included, sent after a pause.
    /// `original` only says which band: the scroll wheel's handler can hold a graph from
    /// before eqtune's last answer.
    private func adjust(_ original: Band, by change: (inout Band) -> Void) {
        let key = key(original.hz)
        guard var edited = drafts[key] ?? band(at: key) else { return }
        change(&edited)
        edit(original, edited, .soon)
    }

    /// Sends what's still being edited (a typed value, a nudge waiting for its pause) and waits
    /// for eqtune's answer, so a save or reset after it sees all of it.
    private func sendEdits() async {
        // A field sends what's typed as it loses focus, on SwiftUI's next update.
        if endTyping() {
            for _ in 0..<25 where typing { try? await Task.sleep(for: .milliseconds(20)) }
        }
        for task in pending.values { await task.value }
    }

    /// Takes the keyboard from a field, which sends what's typed on SwiftUI's next update.
    @discardableResult private func endTyping() -> Bool {
        guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return false }
        return window.makeFirstResponder(nil)
    }

    private func add(_ band: Band) {
        endTyping() // what's typed goes to the band it was typed for, not the new one
        let name = preset.name
        Task {
            await store.addBand(band, to: name)
            guard store.failure == nil, let added = store.activePreset.flatMap({ $0.name == name ? $0 : nil })?
                .bands.first(where: { $0.sitsAt(band.hz) }) else { return }
            moves[added.hz] = nil // it's this band now, not one that moved away from here
            // Typing or a drag that began while eqtune worked carries on: picking the new band
            // now would cut it off.
            guard NSEvent.pressedMouseButtons == 0, !(NSApp.keyWindow?.firstResponder is NSText) else { return }
            select(added.hz)
            graphFocused = true // so the arrow keys move it
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
        let key = key(band.hz)
        if selection == key { selection = nil }
        pending[key]?.cancel() // a change still waiting for its pause goes with the band
        // After any send on its way, so it removes the band from where that one leaves it.
        guard let base = self.band(at: key) else { return }
        let name = preset.name
        pending[key] = Task {
            await store.editBand(base, of: name, to: nil)
            drafts[self.key(key)] = nil
        }
    }
}
