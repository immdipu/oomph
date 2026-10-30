import Charts
import SwiftUI

/// Edits the active preset's bands. Every change goes straight to eqtune (slider drags are
/// debounced); the window always shows what eqtune reports back.
struct BandEditorView: View {
    @Environment(EqtuneStore.self) private var store
    /// Slider values not yet confirmed by eqtune, keyed by band frequency, so the curve
    /// follows a drag live.
    @State private var drafts: [Double: Band] = [:]
    @State private var newBand = Band(kind: .peaking, hz: 1000, db: 0, q: 1)
    @State private var namePrompt: NamePrompt?
    @State private var name = ""
    @State private var confirmDelete = false

    enum NamePrompt { case saveAs, clone }

    var body: some View {
        Group {
            if let status = store.status, let preset = store.activePreset {
                editor(status, preset)
            } else if store.blocker != nil {
                ContentUnavailableView("Can't reach eqtune", systemImage: "exclamationmark.triangle",
                                       description: Text("Open the Oomph menu for details."))
            } else if let problem = store.editorProblem {
                ContentUnavailableView {
                    Label("Can't read this preset", systemImage: "exclamationmark.triangle")
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
        .frame(minWidth: 760, minHeight: 540)
        .navigationTitle("Bands")
        .navigationSubtitle(store.status?.preset ?? "")
        .toolbar { toolbar }
        .alert(namePrompt == .clone ? "Clone Preset" : "Save Preset As",
               isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })) {
            TextField("Name", text: $name)
            Button(namePrompt == .clone ? "Clone" : "Save") { submitName() }
                .disabled(nameProblem != nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(nameProblem ?? "Use letters, digits, “-”, “_” or “.”.")
        }
        .confirmationDialog("Delete “\(store.status?.preset ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await store.deleteActivePreset() } }
        } message: {
            Text("eqtune switches to the first remaining preset. Shipped presets can be restored with `eqtune reset`.")
        }
        .onAppear { store.setVisible(.editor, true) }
        .onDisappear { store.setVisible(.editor, false) }
    }

    private func editor(_ status: EqtuneStatus, _ preset: Preset) -> some View {
        VStack(spacing: 0) {
            ResponseChart(bands: preset.bands.map { drafts[$0.hz] ?? $0 },
                          sampleRate: status.outputRateHz ?? 48_000)
                .frame(height: 190)
                .padding()
            Divider()
            PreampRow(preamp: status.preampDB)
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Type")
                        Text("Frequency (Hz)")
                        Text("Gain (dB)")
                        Text("Q")
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(preset.bands, id: \.hz) { band in
                        BandRow(band: band, preset: preset.name, draft: $drafts[band.hz])
                    }
                }
                .padding()
            }
            Divider()
            addBandRow(preset)
        }
        .onChange(of: preset.name) { drafts = [:] }
    }

    private func addBandRow(_ preset: Preset) -> some View {
        let full = preset.bands.count >= Limits.maxBands
        let taken = preset.bands.contains { abs($0.hz - newBand.clamped.hz) < 0.5 }
        return HStack {
            Picker("Type", selection: $newBand.kind) {
                ForEach(BandKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Hz", value: $newBand.hz, format: .number.grouping(.never)).frame(width: 64)
            Text("Hz").foregroundStyle(.secondary)
            TextField("dB", value: $newBand.db, format: .number).frame(width: 48)
            Text("dB").foregroundStyle(.secondary)
            TextField("Q", value: $newBand.q, format: .number).frame(width: 48)
            Text("Q").foregroundStyle(.secondary)
            Button("Add Band", systemImage: "plus") { Task { await store.addBand(newBand) } }
                .disabled(store.isBusy || full || taken)
            if full {
                Text("A preset holds at most \(Limits.maxBands) bands.").foregroundStyle(.secondary)
            } else if taken {
                Text("A band already sits at that frequency.").foregroundStyle(.secondary)
            }
            Spacer()
            if let failure = store.failure {
                Label(failure.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.callout)
        .padding()
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let status = store.status
        let anyDirty = !(status?.dirtyPresets.isEmpty ?? true)
        let activeDirty = status.map { $0.dirtyPresets.contains($0.preset) } ?? false
        ToolbarItemGroup {
            if activeDirty {
                Label("Unsaved changes", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if store.isBusy { ProgressView().controlSize(.small) }
            Button("Save") { Task { if let status { await store.savePreset(as: status.preset) } } }
                .disabled(store.isBusy || !activeDirty)
                .help("Save these bands to the preset (eqtune preset-save)")
            Button("Save As…") { prompt(.saveAs) }
                .disabled(store.isBusy || status == nil)
            Button("Clone…") { prompt(.clone) }
                .disabled(store.isBusy || status == nil || anyDirty)
                .help(anyDirty ? "Save or discard unsaved changes first" : "Copy this preset under a new name")
            Button("Delete Preset…", role: .destructive) { confirmDelete = true }
                .disabled(store.isBusy || status == nil || anyDirty || store.presets.count < 2)
                .help(anyDirty ? "Save or discard unsaved changes first" : "Delete this preset")
        }
    }

    private func prompt(_ kind: NamePrompt) {
        name = ""
        namePrompt = kind
    }

    /// Saving under the active preset's own name saves in place; a clone needs a new name.
    private var nameProblem: String? {
        store.nameProblem(name.trimmingCharacters(in: .whitespaces), allowActive: namePrompt == .saveAs)
    }

    private func submitName() {
        let name = name.trimmingCharacters(in: .whitespaces)
        let kind = namePrompt
        Task {
            if kind == .clone { await store.cloneActivePreset(to: name) } else { await store.savePreset(as: name) }
        }
    }
}

/// One band: type, frequency, gain and Q, each as a slider plus a number field.
private struct BandRow: View {
    @Environment(EqtuneStore.self) private var store
    let band: Band
    let preset: String
    @Binding var draft: Band?
    @State private var dragging = false
    @State private var pending: Task<Void, Never>?

    private var current: Band { draft ?? band }

    var body: some View {
        GridRow {
            Picker("Type", selection: Binding(get: { current.kind }, set: { kind in
                edit { $0.kind = kind }
                commit(now: true)
            })) {
                ForEach(BandKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 108)

            // Frequency is the band's identity in eqtune, so it's sent on release, not mid-drag.
            // Number fields update as you type; the debounce sends the value once you stop.
            // Sliders step by 1 Hz (10 Hz above 1 kHz), 0.1 dB and 0.01 Q.
            control("Frequency", Binding(get: { log10(current.hz) }, set: { value in
                        let hz = pow(10, value)
                        edit { $0.hz = hz < 1000 ? hz.rounded() : (hz / 10).rounded() * 10 }
                    }),
                    in: log10(Limits.hz.lowerBound)...log10(Limits.hz.upperBound),
                    field: Binding(get: { current.hz }, set: { hz in edit { $0.hz = hz }; commit(now: false) }),
                    format: .number.grouping(.never).precision(.fractionLength(0...2)))
            control("Gain", Binding(get: { current.db }, set: { value in edit { $0.db = (value * 10).rounded() / 10 }; commit(now: false) }),
                    in: Limits.db,
                    field: Binding(get: { current.db }, set: { db in edit { $0.db = db }; commit(now: false) }),
                    format: .number.precision(.fractionLength(1...2)))
            control("Q", Binding(get: { log10(current.q) }, set: { value in edit { $0.q = (pow(10, value) * 100).rounded() / 100 }; commit(now: false) }),
                    in: log10(Limits.q.lowerBound)...log10(Limits.q.upperBound),
                    field: Binding(get: { current.q }, set: { q in edit { $0.q = q }; commit(now: false) }),
                    format: .number.precision(.fractionLength(0...3)))
            Button("Remove band", systemImage: "minus.circle") {
                Task { await store.editBand(band, of: preset, to: nil) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(store.isBusy)
        }
    }

    /// A slider (sent when released) and a number field.
    private func control(_ name: String, _ slider: Binding<Double>, in range: ClosedRange<Double>,
                         field: Binding<Double>, format: FloatingPointFormatStyle<Double>) -> some View {
        HStack(spacing: 6) {
            Slider(value: slider, in: range) { editing in
                dragging = editing
                if !editing { commit(now: true) }
            }
            .frame(minWidth: 100)
            .accessibilityLabel(name)
            .accessibilityValue(field.wrappedValue.formatted(format))
            TextField(name, value: field, format: format)
                .labelsHidden()
                .frame(width: 58)
        }
    }

    private func edit(_ change: (inout Band) -> Void) {
        var band = current
        change(&band)
        draft = band
    }

    /// Sends the draft to eqtune, after 150 ms without changes unless `now`.
    private func commit(now: Bool) {
        pending?.cancel()
        pending = Task {
            if !now { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let edited = draft else { return }
            if edited != band { await store.editBand(band, of: preset, to: edited) }
            // eqtune's answer is on screen now, unless the user kept editing meanwhile.
            if !dragging, draft == edited { draft = nil }
        }
    }
}

private struct PreampRow: View {
    @Environment(EqtuneStore.self) private var store
    let preamp: Double
    @State private var draft: Double?
    @State private var dragging = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Text("Preamp").frame(width: 108, alignment: .leading)
            Slider(value: Binding(get: { draft ?? preamp }, set: { draft = ($0 * 10).rounded() / 10; commit(now: false) }),
                   in: Limits.preamp) { editing in
                dragging = editing
                if !editing { commit(now: true) }
            }
            .accessibilityLabel("Preamp")
            TextField("Preamp", value: Binding(get: { draft ?? preamp }, set: { draft = $0; commit(now: false) }),
                      format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .frame(width: 58)
            Text("dB").foregroundStyle(.secondary)
            Button("Auto") { Task { await store.autoPreamp() } }
                .disabled(store.isBusy)
                .help("Offset the largest boost so the output can't clip (eqtune preamp-auto)")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func commit(now: Bool) {
        pending?.cancel()
        pending = Task {
            if !now { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let value = draft else { return }
            if value != preamp { await store.setPreamp(value) }
            if !dragging, draft == value { draft = nil }
        }
    }
}

/// The EQ curve on a log frequency axis, from the band parameters (no audio involved).
private struct ResponseChart: View {
    let bands: [Band]
    let sampleRate: Double

    private static let frequencies = (0...240).map { 20 * pow(1000, Double($0) / 240) }

    var body: some View {
        Chart {
            RuleMark(y: .value("0 dB", 0))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))
            // Biquads only describe frequencies below Nyquist; at low output rates the curve ends early.
            ForEach(Self.frequencies.filter { $0 < sampleRate / 2 }, id: \.self) { hz in
                LineMark(x: .value("Frequency", hz), y: .value("Gain", gain(at: hz)))
            }
            ForEach(bands.filter { $0.hz < sampleRate / 2 }, id: \.hz) { band in
                PointMark(x: .value("Frequency", band.hz), y: .value("Gain", gain(at: band.hz)))
                    .symbolSize(28)
            }
        }
        .chartXScale(domain: 20...20_000, type: .log)
        .chartYScale(domain: -24...24)
        .chartXAxis {
            AxisMarks(values: [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hz = value.as(Double.self) { Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))") }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [-24, -12, 0, 12, 24]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    private func gain(at hz: Double) -> Double {
        bands.gainDB(at: hz, sampleRate: sampleRate).clamped(to: -24...24)
    }
}

#Preview {
    BandEditorView().environment(EqtuneStore(client: MockEqtuneClient()))
}
