import AppKit
import SwiftUI

// MARK: - Look

extension Color {
    /// The two ends of the app icon's gradient.
    static let oomphOrange = Color(red: 0.99, green: 0.47, blue: 0.23)
    static let oomphPink = Color(red: 0.84, green: 0.14, blue: 0.51)
}

extension LinearGradient {
    static let oomph = LinearGradient(colors: [.oomphOrange, .oomphPink], startPoint: .leading, endPoint: .trailing)
}

extension Animation {
    /// How things move when eqtune's answer changes the window: quick enough to follow,
    /// slow enough to see what changed.
    static let oomph = Animation.smooth(duration: 0.35)
}

/// One color per band, in frequency order, shared by the graph and the band list.
enum BandColors {
    private static let palette: [Color] = [.orange, .pink, .purple, .blue, .cyan, .green, .yellow, .red, .indigo, .mint, .teal]

    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

// MARK: - Numbers

/// How Oomph writes values, so the menu, the equalizer and the graph agree.
enum Format {
    /// "+3.5 dB", "−12 dB", "0 dB"
    static func db(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return (rounded == 0 ? 0 : rounded)
            .formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always(includingZero: false))) + " dB"
    }

    /// "32 Hz", "1.25 kHz", "16 kHz"
    static func hz(_ value: Double) -> String {
        value < 1000
            ? value.formatted(.number.precision(.fractionLength(0...1))) + " Hz"
            : (value / 1000).formatted(.number.precision(.fractionLength(0...2))) + " kHz"
    }

    /// "20–60 Hz", "500 Hz–2 kHz", "6–20 kHz"
    static func range(_ range: ClosedRange<Double>) -> String {
        let (low, high) = (hz(range.lowerBound), hz(range.upperBound))
        let unit = high.hasSuffix("kHz") ? " kHz" : " Hz"
        return low.hasSuffix(unit) ? "\(low.dropLast(unit.count))–\(high)" : "\(low)–\(high)"
    }

    /// "20", "500", "1k", "10k": graph axis labels.
    static func axisHz(_ value: Double) -> String {
        value < 1000 ? "\(Int(value))" : "\(Int(value / 1000))k"
    }

    static func q(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Library presets show their title; everything else shows eqtune's name.
func displayName(_ preset: String) -> String {
    SoundLibrary.preset(preset)?.title ?? preset
}

// MARK: - Building blocks

/// A small heading above a group of controls, with room for a control on the right.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The last command that failed, with eqtune's raw output when Oomph couldn't read it.
struct FailureBanner: View {
    let failure: EqtuneStore.Failure
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let raw = failure.raw {
                    DisclosureGroup("eqtune output") {
                        ScrollView {
                            Text(raw)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A switch for a setting eqtune owns. It keeps the new position while eqtune applies it
/// (about half a second) instead of flipping back until eqtune's answer arrives.
struct EqtuneToggle<Label: View>: View {
    let isOn: Bool
    let change: @MainActor (Bool) async -> Void
    @ViewBuilder let label: (_ isOn: Bool) -> Label
    @State private var pending: Bool?
    @State private var flips = 0

    var body: some View {
        Toggle(isOn: Binding(get: { pending ?? isOn }, set: { on in
            pending = on
            flips += 1
            let flip = flips
            Task {
                await change(on)
                if flips == flip { pending = nil } // flipped again meanwhile: that one settles it
            }
        })) {
            label(pending ?? isOn)
        }
    }
}

/// A small spinner while a command runs. Most commands finish before it shows, so it
/// doesn't flash on every click, and it keeps its place so the controls beside it don't move.
struct BusyIndicator: View {
    let isBusy: Bool
    @State private var shown = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
            .task(id: isBusy) {
                if isBusy, (try? await Task.sleep(for: .milliseconds(600))) == nil { return }
                withAnimation(.oomph) { shown = isBusy }
            }
    }
}

/// What the EQ is doing right now, as a colored dot and a few words.
struct StatusLine: View {
    let status: EqtuneStatus
    let isFailing: Bool

    var body: some View {
        let (color, text) = Self.describe(status, isFailing: isFailing)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    static func describe(_ status: EqtuneStatus, isFailing: Bool) -> (Color, String) {
        if !status.isOn { return (.gray, "Off · your Mac’s original sound") }
        if isFailing { return (.red, "Not running") }
        if status.engineRunning {
            return status.bypass ? (.orange, "Bypassed · hearing the original") : (.green, outputLine(status))
        }
        return switch status.suspension {
        case "idle": (.gray, "Paused until audio plays")
        case "low-power": (.gray, "Paused in Low Power Mode")
        default: (.yellow, "Starting…")
        }
    }

    static func outputLine(_ status: EqtuneStatus) -> String {
        let name = status.outputName ?? "No output device"
        guard let rate = status.outputRateHz else { return name }
        return "\(name) · \((rate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }
}

/// Press and hold to hear the Mac without the EQ; let go to hear it again. Switching back
/// and forth quickly is the surest way to hear whether a change is actually better.
struct HoldToCompareButton: View {
    @Environment(EqtuneStore.self) private var store
    @State private var holding = false

    var body: some View {
        Label(holding ? "Original" : "Hold to Compare", systemImage: holding ? "ear.fill" : "ear")
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(holding ? AnyShapeStyle(LinearGradient.oomph.opacity(0.35)) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 6))
            .animation(.smooth(duration: 0.15), value: holding)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    Task { await store.setBypass(true) }
                }
                .onEnded { _ in
                    holding = false
                    Task { await store.setBypass(false) }
                })
            .onDisappear {
                guard holding else { return }
                holding = false
                Task { await store.setBypass(false) }
            }
            .help("Hold to hear your Mac without the EQ; let go to hear it with the EQ")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Compare with the original sound")
            .accessibilityAction { Task { await store.setBypass(!(store.status?.bypass ?? false)) } }
    }
}

/// A full-width, menu-style row button that highlights on hover.
struct MenuRow<Label: View>: View {
    var shortcut: String?
    let action: () -> Void
    let label: Label
    @State private var hovering = false

    init(shortcut: String? = nil, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.shortcut = shortcut
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 8)
                if let shortcut { Text("⌘\(shortcut)").foregroundStyle(hovering ? .white.opacity(0.8) : .secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(hovering ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension MenuRow where Label == Text {
    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.init(shortcut: shortcut, action: action) { Text(title) }
    }
}

/// A slider with a typed-in value next to it. The slider reports `live` changes while
/// dragging and `final` on release; the field is final when the user presses Return.
struct ValueSlider: View {
    enum Change { case live, final }

    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var logarithmic = false
    var step: Double = 0
    let format: FloatingPointFormatStyle<Double>
    var unit: String = ""
    let onChange: (Double, Change) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { position(value) }, set: { onChange(snap(value(at: $0)), .live) }),
                   in: position(range.lowerBound)...position(range.upperBound)) { editing in
                if !editing { onChange(value, .final) }
            }
            .accessibilityLabel(title)
            .accessibilityValue("\(value.formatted(format)) \(unit)")
            TextField(title, value: Binding(get: { value }, set: { onChange($0.clamped(to: range), .final) }), format: format)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text(unit).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
        }
    }

    private func position(_ value: Double) -> Double { logarithmic ? log10(value) : value }
    private func value(at position: Double) -> Double { logarithmic ? pow(10, position) : position }
    private func snap(_ value: Double) -> Double { step > 0 ? (value / step).rounded() * step : value }
}
