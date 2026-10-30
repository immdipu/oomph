import AppKit
import SwiftUI

/// When an edit made in the UI goes to eqtune: `live` only redraws (mid-drag), `soon`
/// waits for a pause (scrolling, typing), `now` sends it right away (a release).
enum EditTiming { case live, soon, now }

/// Maps frequency and gain to points: log frequency across 20 Hz–20 kHz, linear gain
/// across ±`range` dB.
struct GraphScale {
    var size: CGSize
    var range: Double

    func x(_ hz: Double) -> CGFloat { size.width * CGFloat(log10(hz / 20) / 3) }
    func hz(_ x: CGFloat) -> Double { 20 * pow(1000, Double(x / max(size.width, 1))) }
    func y(_ db: Double) -> CGFloat { size.height / 2 * CGFloat(1 - db / range) }
    func db(_ y: CGFloat) -> Double { (1 - Double(y / max(size.height / 2, 1))) * range }

    /// Where a band's point sits: on its own curve at its frequency. That's the full gain
    /// for a peak, and half of it for a shelf, whose corner is halfway up its slope.
    func nodeY(_ band: Band) -> CGFloat {
        y((band.kind == .peaking ? band.db : band.db / 2).clamped(to: -range...range))
    }

    /// The band gain that puts its point at `y`.
    func gain(forNodeAt y: CGFloat, kind: BandKind) -> Double {
        let level = db(y).clamped(to: -range...range)
        return ((kind == .peaking ? level : level * 2).clamped(to: Limits.db) * 10).rounded() / 10
    }
}

/// A curve as heights from -1 (the graph's bottom) to 1 (its top) at frequencies spread
/// evenly across the graph. As a vector, it lets SwiftUI morph one curve into another.
struct CurveLevels: VectorArithmetic {
    /// 20 Hz to 20 kHz, log-spaced: about one per 2 points across a wide graph.
    static let frequencies = (0..<600).map { 20 * pow(1000, Double($0) / 599) }

    var values: [Double]

    /// `bands`' curve on a ±`range` dB scale. Biquads only describe frequencies below
    /// Nyquist, so at low output rates the curve ends early.
    init(_ bands: [Band], sampleRate: Double, range: Double) {
        let frequencies = Self.frequencies.filter { $0 < sampleRate / 2 }
        values = bands.curve(at: frequencies, sampleRate: sampleRate).map { ($0 / range).clamped(to: -1...1) }
    }

    private init(values: [Double]) { self.values = values }

    static var zero: CurveLevels { CurveLevels(values: []) }
    static func + (lhs: CurveLevels, rhs: CurveLevels) -> CurveLevels { combine(lhs, rhs, +) }
    static func - (lhs: CurveLevels, rhs: CurveLevels) -> CurveLevels { combine(lhs, rhs, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    /// Value by value; `zero` is empty, so a missing value counts as 0.
    private static func combine(_ lhs: CurveLevels, _ rhs: CurveLevels, _ op: (Double, Double) -> Double) -> CurveLevels {
        CurveLevels(values: (0..<max(lhs.values.count, rhs.values.count)).map { index in
            op(index < lhs.values.count ? lhs.values[index] : 0, index < rhs.values.count ? rhs.values[index] : 0)
        })
    }
}

/// A curve as a line, or as the area between it and 0 dB.
struct CurveShape: Shape {
    var levels: CurveLevels
    var filled = false

    var animatableData: CurveLevels {
        get { levels }
        set { levels = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let step = rect.width / CGFloat(CurveLevels.frequencies.count - 1)
        let points = levels.values.enumerated().map { index, level in
            CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.midY - rect.height / 2 * CGFloat(level))
        }
        guard let first = points.first, let last = points.last else { return Path() }
        var path = Path()
        // addLines starts a new subpath, so the 0 dB ends go in the same call.
        path.addLines(filled ? [CGPoint(x: first.x, y: rect.midY)] + points + [CGPoint(x: last.x, y: rect.midY)] : points)
        if filled { path.closeSubpath() }
        return path
    }
}

/// A band's filter shape drawn small: a bell for a peak, a step for a shelf.
struct FilterShape: Shape {
    let kind: BandKind

    func path(in r: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .peaking:
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            path.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX + r.width * 0.3, y: r.maxY),
                          control2: CGPoint(x: r.midX - r.width * 0.15, y: r.minY))
            path.addCurve(to: CGPoint(x: r.maxX, y: r.maxY), control1: CGPoint(x: r.midX + r.width * 0.15, y: r.minY),
                          control2: CGPoint(x: r.maxX - r.width * 0.3, y: r.maxY))
        case .lowShelf, .highShelf:
            let (start, end) = kind == .lowShelf ? (r.minY, r.maxY) : (r.maxY, r.minY)
            path.move(to: CGPoint(x: r.minX, y: start))
            path.addLine(to: CGPoint(x: r.minX + r.width * 0.2, y: start))
            path.addCurve(to: CGPoint(x: r.maxX - r.width * 0.2, y: end), control1: CGPoint(x: r.midX, y: start),
                          control2: CGPoint(x: r.midX, y: end))
            path.addLine(to: CGPoint(x: r.maxX, y: end))
        }
        return path
    }
}

/// The EQ curve with its grid. `detailed` adds axis labels and the named frequency zones;
/// without it, it's the small preview in the menu.
struct EQCurveView: View {
    var bands: [Band]
    var sampleRate: Double
    var range: Double = 12
    var detailed = false
    /// A band drawn on its own under the total curve, in its color.
    var highlight: (band: Band, color: Color)?

    private static let majorHz: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
    private static let minorHz: [Double] = [30, 40, 60, 70, 80, 90, 300, 400, 600, 700, 800, 900,
                                            3000, 4000, 6000, 7000, 8000, 9000]

    var body: some View {
        let levels = CurveLevels(bands, sampleRate: sampleRate, range: range)
        ZStack {
            axes
            if let highlight {
                let own = CurveLevels([highlight.band], sampleRate: sampleRate, range: range)
                // Fades in and out on its own, so selecting a band animates nothing else here.
                Group {
                    CurveShape(levels: own, filled: true).fill(highlight.color.opacity(0.18))
                    CurveShape(levels: own).stroke(highlight.color.opacity(0.8), lineWidth: 1)
                }
                .transition(.opacity.animation(.oomph))
            }
            CurveShape(levels: levels, filled: true)
                .fill(LinearGradient(colors: [.oomphOrange.opacity(0.22), .oomphPink.opacity(0.22)],
                                     startPoint: .leading, endPoint: .trailing))
            CurveShape(levels: levels)
                .stroke(LinearGradient.oomph, style: StrokeStyle(lineWidth: detailed ? 2.5 : 1.75, lineCap: .round, lineJoin: .round))
        }
        .accessibilityElement()
        .accessibilityLabel("Frequency response")
        .accessibilityValue(Self.summary(bands))
    }

    /// The grid and its labels; the curves are shapes on top, so they can animate.
    private var axes: some View {
        Canvas { context, size in
            let scale = GraphScale(size: size, range: range)
            let grid = Color.secondary.opacity(0.18)

            if detailed {
                for (index, zone) in FrequencyZone.allCases.enumerated() {
                    let rect = CGRect(x: scale.x(zone.range.lowerBound), y: 0,
                                      width: scale.x(zone.range.upperBound) - scale.x(zone.range.lowerBound), height: size.height)
                    if index.isMultiple(of: 2) { context.fill(Path(rect), with: .color(.primary.opacity(0.03))) }
                    context.draw(Text(zone.name).font(.caption2.weight(.medium)).foregroundStyle(.secondary),
                                 at: CGPoint(x: rect.midX, y: 6), anchor: .top)
                }
                for hz in Self.minorHz {
                    context.stroke(Path { $0.addLines([CGPoint(x: scale.x(hz), y: 0), CGPoint(x: scale.x(hz), y: size.height)]) },
                                   with: .color(grid.opacity(0.5)), lineWidth: 0.5)
                }
            }
            for hz in Self.majorHz {
                context.stroke(Path { $0.addLines([CGPoint(x: scale.x(hz), y: 0), CGPoint(x: scale.x(hz), y: size.height)]) },
                               with: .color(grid), lineWidth: 0.5)
                if detailed, hz > 20, hz < 20_000 {
                    context.draw(Text(Format.axisHz(hz)).font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: scale.x(hz), y: size.height - 4), anchor: .bottom)
                }
            }
            for db in stride(from: -range, through: range, by: range / 4) {
                let y = scale.y(db)
                context.stroke(Path { $0.addLines([CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)]) },
                               with: .color(db == 0 ? Color.secondary.opacity(0.5) : grid), lineWidth: db == 0 ? 1 : 0.5)
                if detailed, abs(db) < range {
                    context.draw(Text(db == 0 ? "0 dB" : db.formatted(.number.sign(strategy: .always(includingZero: false))))
                                    .font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: 4, y: y - 2), anchor: .bottomLeading)
                }
            }
        }
    }

    /// The curve in words for VoiceOver: the biggest boost and cut.
    static func summary(_ bands: [Band]) -> String {
        guard !bands.isEmpty else { return "Flat" }
        let points = (0...60).map { 20 * pow(1000, Double($0) / 60) }
        let gains = bands.curve(at: points, sampleRate: 48_000)
        let top = zip(points, gains).max { $0.1 < $1.1 }!, bottom = zip(points, gains).min { $0.1 < $1.1 }!
        return "Biggest boost \(Format.db(top.1)) at \(Format.hz(top.0)), biggest cut \(Format.db(bottom.1)) at \(Format.hz(bottom.0))"
    }
}

/// The equalizer's graph: drag a point to move a band, scroll over the graph to change the
/// selected band's width, double-click to add a band, arrow keys to nudge, Delete to remove.
struct EQGraph: View {
    /// The preset the bands belong to.
    let preset: String
    /// The bands as eqtune has them; they identify each point.
    let bands: [Band]
    /// The same bands with unsent edits applied, in the same order.
    let shown: [Band]
    let sampleRate: Double
    let range: Double
    @Binding var selection: Double?
    /// Whether the graph has the keyboard, for the arrow keys. The editor gives it the
    /// keyboard when a band is picked elsewhere too.
    var focused: FocusState<Bool>.Binding
    let onEdit: (_ original: Band, _ edited: Band, EditTiming) -> Void
    /// Changes a band by a step from wherever it is now, unsent edits included. Keys and the
    /// scroll wheel can fire faster than the graph redraws, when `shown` is a step behind.
    let onAdjust: (_ original: Band, _ change: (inout Band) -> Void) -> Void
    let onAdd: (Band) -> Void
    let onRemove: (Band) -> Void

    @State private var hover: CGPoint?
    @State private var wheel = ScrollWheel()

    init(preset: String, bands: [Band], shown: [Band], sampleRate: Double, range: Double, selection: Binding<Double?>,
         focused: FocusState<Bool>.Binding,
         onEdit: @escaping (Band, Band, EditTiming) -> Void, onAdjust: @escaping (Band, (inout Band) -> Void) -> Void,
         onAdd: @escaping (Band) -> Void, onRemove: @escaping (Band) -> Void) {
        self.preset = preset
        self.bands = bands
        self.shown = shown
        self.sampleRate = sampleRate
        self.range = range
        _selection = selection
        self.focused = focused
        self.onEdit = onEdit
        self.onAdjust = onAdjust
        self.onAdd = onAdd
        self.onRemove = onRemove
    }

    private var selectedIndex: Int? { bands.firstIndex { $0.hz == selection } }

    var body: some View {
        GeometryReader { geometry in
            let scale = GraphScale(size: geometry.size, range: range)
            ZStack(alignment: .topLeading) {
                EQCurveView(bands: shown, sampleRate: sampleRate, range: range, detailed: true,
                            highlight: selectedIndex.map { (shown[$0], BandColors.color($0)) })
                if let hover { readout(at: hover, scale: scale) }
                ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                    BandNode(preset: preset, index: index, original: band, shown: shown[index], scale: scale,
                             isSelected: band.hz == selection,
                             onSelect: { selection = band.hz; focused.wrappedValue = true },
                             onEdit: onEdit,
                             onRemove: { onRemove(band) })
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { add(at: $0.location, scale: scale) }
                .exclusively(before: TapGesture().onEnded { selection = nil }))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hover = point
                    wheel.start()
                case .ended:
                    hover = nil
                    wheel.stop()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .focusable()
        .focusEffectDisabled()
        .focused(focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .delete, .deleteForward, Self.deleteKey]) { press in
            nudge(press.key, large: press.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .onAppear { wheel.handler = scrollQ }
        .onChange(of: bands) { wheel.handler = scrollQ }
        .onChange(of: shown) { wheel.handler = scrollQ }
        .onChange(of: selection) {
            wheel.handler = scrollQ
            wheel.q = nil
        }
        .onDisappear { wheel.stop() }
    }

    private func readout(at point: CGPoint, scale: GraphScale) -> some View {
        let hz = scale.hz(point.x).clamped(to: Limits.hz)
        let gain = shown.gainDB(at: hz, sampleRate: sampleRate)
        return ZStack(alignment: .topLeading) {
            Path { $0.addLines([CGPoint(x: point.x, y: 0), CGPoint(x: point.x, y: scale.size.height)]) }
                .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // As wide as the widest reading, so it doesn't resize as the pointer moves.
            Text("00.00 kHz · Upper mids · +00.0 dB").hidden()
                .overlay { Text("\(Format.hz(hz)) · \(FrequencyZone.at(hz).name) · \(Format.db(gain))") }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
                .position(x: min(max(point.x, 96), scale.size.width - 96), y: 32) // half its width, and a margin
        }
        .allowsHitTesting(false)
    }

    private func add(at point: CGPoint, scale: GraphScale) {
        let hz = scale.hz(point.x).clamped(to: Limits.hz)
        let rounded = hz < 1000 ? hz.rounded() : (hz / 10).rounded() * 10
        let free = Preset(name: "", preampDB: 0, bands: bands).freeFrequency(near: rounded)
        onAdd(Band(kind: .peaking, hz: free, db: (scale.db(point.y) * 2).rounded() / 2, q: 1))
    }

    /// What the Delete key types on a Mac (U+007F). SwiftUI's `.delete` is U+0008, which it
    /// doesn't send.
    private static let deleteKey = KeyEquivalent("\u{7F}")

    /// Up/down: 0.5 dB (3 with Shift). Left/right: 1/12 octave (half an octave with Shift).
    private func nudge(_ key: KeyEquivalent, large: Bool) -> Bool {
        guard let index = selectedIndex else { return false }
        let band = bands[index]
        switch key {
        case .delete, .deleteForward, Self.deleteKey:
            onRemove(band)
        case .upArrow, .downArrow:
            let step = (key == .upArrow ? 1 : -1) * (large ? 3 : 0.5)
            onAdjust(band) { $0.db = ($0.db + step).clamped(to: Limits.db) }
        default:
            let factor = pow(2, (key == .rightArrow ? 1 : -1) * (large ? 0.5 : 1.0 / 12))
            onAdjust(band) { band in
                let hz = (band.hz * factor).clamped(to: Limits.hz)
                band.hz = hz < 1000 ? hz.rounded() : (hz / 10).rounded() * 10
            }
        }
        return true
    }

    /// Scrolling up narrows the selected band (higher Q), scrolling down widens it. Q counts on
    /// unrounded: slow scrolling moves a wide band's Q by less than 0.01 per step.
    private func scrollQ(_ delta: CGFloat) -> Bool {
        guard let index = selectedIndex else { return false }
        onAdjust(bands[index]) { band in
            let start = wheel.q.flatMap { ($0 * 100).rounded() / 100 == band.q ? $0 : nil } ?? band.q
            let q = (start * exp(Double(delta) * 0.02)).clamped(to: Limits.q)
            wheel.q = q
            band.q = (q * 100).rounded() / 100
        }
        return true
    }
}

/// One draggable point on the graph, numbered and colored like its band.
private struct BandNode: View {
    let preset: String
    let index: Int
    let original: Band
    let shown: Band
    let scale: GraphScale
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: (_ original: Band, _ edited: Band, EditTiming) -> Void
    let onRemove: () -> Void
    @State private var hovering = false
    /// The drag under way: where it began, on which preset, its band as eqtune had it and as
    /// drawn then, and where it has got to. It carries on from an edit eqtune hasn't answered
    /// yet, stays with its band when an answer re-sorts the points under it, and ends quietly
    /// if another preset arrives under it.
    @State private var drag: (start: CGPoint, preset: String, original: Band, shown: Band, last: Band)?

    var body: some View {
        let size: CGFloat = isSelected ? 20 : 16
        Text("\(index + 1)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(BandColors.color(index), in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 2 : 1))
            .shadow(color: .black.opacity(0.3), radius: isSelected ? 3 : 1)
            .animation(.snappy(duration: 0.2), value: isSelected) // before .position: the point never lags
            .scaleEffect(hovering ? 1.15 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Circle().inset(by: -6))
            .onHover { hovering = $0 }
            // Measured in the window: the point moves with the drag, and in its own coordinates
            // each move would shift the next reading, so it lagged and jumped back and forth.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if drag?.start != value.startLocation {
                        drag = (value.startLocation, preset, original, shown, shown)
                        if !isSelected { onSelect() }
                    }
                    edit(value, .live)
                }
                .onEnded { value in
                    edit(value, .now)
                    drag = nil
                })
            .contextMenu {
                ForEach(BandKind.allCases, id: \.self) { kind in
                    Toggle(kind.label, isOn: Binding(get: { shown.kind == kind }, set: { _ in
                        var edited = shown
                        edited.kind = kind
                        onEdit(original, edited, .now)
                    }))
                }
                Divider()
                Button("Remove Band", role: .destructive, action: onRemove)
            }
            .help("\(shown.kind.label) · \(Format.hz(shown.hz)) · \(Format.db(shown.db)) · Q \(Format.q(shown.q))")
            .accessibilityElement()
            .accessibilityLabel("Band \(index + 1), \(shown.kind.label)")
            .accessibilityValue("\(Format.hz(shown.hz)), \(Format.db(shown.db))")
            .accessibilityAdjustableAction { direction in
                var edited = shown
                edited.db = (edited.db + (direction == .increment ? 0.5 : -0.5)).clamped(to: Limits.db)
                onEdit(original, edited, .soon)
            }
            // Removed mid-drag (eqtune's answer to removing a band before it): no onEnded comes,
            // so send where the drag got to.
            .onDisappear { if let drag, drag.preset == preset { onEdit(drag.original, drag.last, .now) } }
            .position(x: scale.x(shown.hz), y: scale.nodeY(shown))
    }

    /// The band moved by the drag from where it began. Holding Shift changes only the gain.
    private func edit(_ value: DragGesture.Value, _ timing: EditTiming) {
        if let drag, drag.preset != preset { return } // its band went with the old preset
        let (original, start) = drag.map { ($0.original, $0.shown) } ?? (original, shown)
        var band = start
        if abs(value.translation.width) >= 1, !NSEvent.modifierFlags.contains(.shift) {
            let hz = scale.hz(scale.x(start.hz) + value.translation.width).clamped(to: Limits.hz)
            band.hz = hz < 1000 ? hz.rounded() : (hz / 10).rounded() * 10
        }
        if abs(value.translation.height) >= 1 {
            band.db = scale.gain(forNodeAt: scale.nodeY(start) + value.translation.height, kind: start.kind)
        }
        drag?.last = band
        onEdit(original, band, timing)
    }
}

/// Hands scroll-wheel moves over the graph to the latest handler, which says whether it
/// used them. A local monitor, because SwiftUI on macOS 14 has no scroll-wheel gesture.
@MainActor
private final class ScrollWheel {
    var handler: ((CGFloat) -> Bool)?
    /// The selected band's Q as scrolled, before rounding.
    var q: Double?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
            let used = MainActor.assumeIsolated { self?.handler?(delta) == true }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        q = nil
    }
}
