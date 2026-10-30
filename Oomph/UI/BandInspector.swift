import SwiftUI

/// Every band as a chip, colored and numbered like its point on the graph.
struct BandStrip: View {
    let bands: [Band]
    let selected: Int?
    let canAdd: Bool
    let onSelect: (Int) -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                        Button { onSelect(index) } label: { chip(index, band) }
                            .buttonStyle(.plain)
                            .id(index)
                    }
                    Button("Add Band", systemImage: "plus", action: onAdd)
                        .disabled(!canAdd)
                        .help(canAdd ? "Add a band where the spectrum has the most room" : "A preset holds at most \(Limits.maxBands) bands")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: selected) { if let selected { withAnimation { proxy.scrollTo(selected) } } }
        }
    }

    private func chip(_ index: Int, _ band: Band) -> some View {
        let isSelected = index == selected
        return HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(BandColors.color(index), in: Circle())
            FilterShape(kind: band.kind)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 16, height: 9)
                .accessibilityLabel(band.kind.label)
            Text(Format.hz(band.hz))
            Text(Format.db(band.db))
                .foregroundStyle(band.db == 0 ? .secondary : .primary)
        }
        .font(.callout.monospacedDigit())
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(isSelected ? AnyShapeStyle(BandColors.color(index).opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? BandColors.color(index) : .clear, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The selected band's controls, with what the band does in plain words.
struct BandInspector: View {
    let index: Int
    let band: Band
    let onEdit: (Band, EditTiming) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(BandColors.color(index), in: Circle())
                    Picker("Type", selection: Binding(get: { band.kind }, set: { change(\.kind, $0, .now) })) {
                        ForEach(BandKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(band.kind.explanation)
                    .font(.callout)
                Text(FrequencyZone.describe(band))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove Band", systemImage: "trash", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
            }
            .frame(width: 300, alignment: .leading)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Frequency")
                    ValueSlider(title: "Frequency", value: band.hz, range: Limits.hz, logarithmic: true,
                                format: .number.grouping(.never).precision(.fractionLength(0...1)), unit: "Hz") { value, phase in
                        // Frequency is the band's identity in eqtune, so it moves on release.
                        change(\.hz, value < 1000 ? value.rounded() : (value / 10).rounded() * 10, phase == .live ? .live : .now)
                    }
                }
                GridRow {
                    Text("Gain")
                    ValueSlider(title: "Gain", value: band.db, range: Limits.db, step: 0.1,
                                format: .number.precision(.fractionLength(1)), unit: "dB") { value, phase in
                        change(\.db, value, phase == .live ? .live : .now)
                    }
                }
                GridRow {
                    Text(band.kind == .peaking ? "Width (Q)" : "Slope (Q)")
                        .help(band.kind == .peaking ? "Lower values affect a wider range of frequencies" : "Higher values make a steeper corner")
                    ValueSlider(title: "Q", value: band.q, range: Limits.q, logarithmic: true,
                                format: .number.precision(.fractionLength(2)), unit: "") { value, phase in
                        change(\.q, (value * 100).rounded() / 100, phase == .live ? .live : .now)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func change<Value>(_ field: WritableKeyPath<Band, Value>, _ value: Value, _ timing: EditTiming) {
        var edited = band
        edited[keyPath: field] = value
        onEdit(edited, timing)
    }
}

/// The preamp, and whether the curve leaves room for loud audio.
struct OutputBar: View {
    @Environment(EqtuneStore.self) private var store
    let status: EqtuneStatus
    let preset: Preset
    /// The bands as shown, drafts included, so the headroom reading follows a drag.
    let bands: [Band]
    @State private var draft: Double?
    @State private var pending: Task<Void, Never>?

    init(status: EqtuneStatus, preset: Preset, bands: [Band]) {
        self.status = status
        self.preset = preset
        self.bands = bands
    }

    var body: some View {
        let preamp = draft ?? preset.preampDB
        let overload = Preset(name: preset.name, preampDB: preamp, bands: bands).overloadDB(sampleRate: status.outputRateHz ?? 48_000)
        HStack(spacing: 12) {
            Text("Preamp")
                .help("Overall level after the EQ. Lower it to make room for boosts.")
            ValueSlider(title: "Preamp", value: preamp, range: -24...12, step: 0.1,
                        format: .number.precision(.fractionLength(1)), unit: "dB") { value, phase in
                draft = value
                commit(value, now: phase == .final)
            }
            .frame(maxWidth: 380)
            Button("Auto") { Task { await store.autoPreamp() } }
                .disabled(store.isBusy)
                .help("Set the preamp so the biggest boost can’t push loud audio past full scale")
            Spacer()
            if overload < 0.1 {
                Label("Headroom OK", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Your boosts fit: loud audio won’t distort.")
            } else {
                Label("Loud parts may distort (\(Format.db(overload)))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Your boosts can push loud audio \(Format.db(overload)) past full scale\(status.limiter ? "; the limiter softens it, but it can still sound strained" : ""). Click Auto to make room.")
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .onChange(of: preset.name) { draft = nil }
    }

    /// Sends the preamp on release, or after a pause while dragging or typing.
    private func commit(_ value: Double, now: Bool) {
        pending?.cancel()
        pending = Task {
            if !now { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            if value != preset.preampDB { await store.setPreamp(value) }
            if draft == value { draft = nil }
        }
    }
}

/// What each part of the spectrum sounds like, shown while no band is selected.
struct FrequencyGuide: View {
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(hint, systemImage: "hand.point.up.left")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                ForEach(FrequencyZone.allCases, id: \.self) { zone in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(zone.name).font(.callout.weight(.semibold))
                        Text(Format.range(zone.range)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(zone.character).font(.caption).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
