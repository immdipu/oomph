import Foundation

/// One `eqtune status` snapshot. The store keeps only the latest one, so nothing can drift.
struct EqtuneStatus: Equatable, Sendable {
    var isOn: Bool                  // `intent`: what the user asked for
    var engineRunning: Bool         // `engine`: whether audio is actually being processed
    var suspension: String?         // why the engine is paused (idle, low-power, recovering, …)
    var preset: String
    var preampDB: Double
    var bandCount: Int
    var limiter: Bool
    var outputUID: String?
    var outputName: String?
    var outputRateHz: Double?
    var lastError: String?
    var bypass: Bool
    var dirtyPresets: [String]
    var autoOffLowPower: Bool
    var autoOffIdle: Bool

    /// The active preset has edits that aren't saved yet.
    var activeIsDirty: Bool { dirtyPresets.contains(preset) }
}

enum BandKind: String, CaseIterable, Sendable {
    case peaking, lowShelf, highShelf

    /// The eqtune subcommand that sets a band of this kind.
    var command: String {
        switch self {
        case .peaking: "band"
        case .lowShelf: "low-shelf"
        case .highShelf: "high-shelf"
        }
    }

    /// The name in preset files (`kind = "low_shelf"`).
    var fileName: String {
        switch self {
        case .peaking: "peaking"
        case .lowShelf: "low_shelf"
        case .highShelf: "high_shelf"
        }
    }

    var label: String {
        switch self {
        case .peaking: "Peak"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        }
    }

    /// What the band does, for people who don't know filter names.
    var explanation: String {
        switch self {
        case .peaking: "Raises or lowers a range around one frequency."
        case .lowShelf: "Raises or lowers everything below its frequency."
        case .highShelf: "Raises or lowers everything above its frequency."
        }
    }
}

struct Band: Hashable, Sendable {
    var kind: BandKind
    var hz: Double
    var db: Double
    var q: Double

    /// Within what eqtune accepts.
    var clamped: Band {
        Band(kind: kind, hz: hz.clamped(to: Limits.hz), db: db.clamped(to: Limits.db), q: q.clamped(to: Limits.q))
    }

    /// eqtune matches a band by frequency, within half a hertz.
    func sitsAt(_ frequency: Double) -> Bool { abs(hz - frequency) < 0.5 }
}

/// A preset as `eqtune preset-show` or `preset-export` describes it.
struct Preset: Equatable, Sendable {
    var name: String
    var preampDB: Double
    var bands: [Band]

    /// eqtune's rule for new preset names.
    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9._-]{1,64}/) != nil
    }
}

/// What eqtune accepts; it rejects anything outside these.
enum Limits {
    static let hz: ClosedRange<Double> = 20...20_000
    static let db: ClosedRange<Double> = -24...24
    static let q: ClosedRange<Double> = 0.1...10
    static let preamp: ClosedRange<Double> = -60...12
    static let maxBands = 64
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Frequency response (display only; eqtune does the audio)

/// One biquad's numerator and denominator coefficients.
struct Biquad {
    var b: (Double, Double, Double)
    var a: (Double, Double, Double)

    /// Gain in dB at `frequency`, from |H(e^jw)|² of numerator and denominator.
    func gainDB(at frequency: Double, sampleRate fs: Double) -> Double {
        let w = 2 * .pi * frequency / fs
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        func power(_ k: (Double, Double, Double)) -> Double {
            let re = k.0 + k.1 * c1 + k.2 * c2
            let im = k.1 * s1 + k.2 * s2
            return re * re + im * im
        }
        return 10 * log10(power(b) / power(a))
    }
}

extension Band {
    /// The same RBJ cookbook biquad eqtune uses (shelves take Q directly, no slope parameter).
    func biquad(sampleRate fs: Double) -> Biquad {
        let a = pow(10, db / 40)
        let w0 = 2 * .pi * hz / fs
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let beta = 2 * a.squareRoot() * alpha
        return switch kind {
        case .peaking:
            Biquad(b: (1 + alpha * a, -2 * c, 1 - alpha * a),
                   a: (1 + alpha / a, -2 * c, 1 - alpha / a))
        case .lowShelf:
            Biquad(b: (a * ((a + 1) - (a - 1) * c + beta), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - beta)),
                   a: ((a + 1) + (a - 1) * c + beta, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - beta))
        case .highShelf:
            Biquad(b: (a * ((a + 1) + (a - 1) * c + beta), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - beta)),
                   a: ((a + 1) - (a - 1) * c + beta, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - beta))
        }
    }

    /// This band's gain in dB at `frequency`.
    func gainDB(at frequency: Double, sampleRate fs: Double) -> Double {
        biquad(sampleRate: fs).gainDB(at: frequency, sampleRate: fs)
    }
}

extension [Band] {
    /// The EQ curve at `frequency`: every band's gain summed in dB (preamp not included).
    func gainDB(at frequency: Double, sampleRate: Double) -> Double {
        reduce(0) { $0 + $1.gainDB(at: frequency, sampleRate: sampleRate) }
    }

    /// The curve at each of `frequencies`, working out each band's filter only once.
    func curve(at frequencies: [Double], sampleRate fs: Double) -> [Double] {
        let filters = map { $0.biquad(sampleRate: fs) }
        return frequencies.map { f in filters.reduce(0) { $0 + $1.gainDB(at: f, sampleRate: fs) } }
    }

    /// The curve's highest point, never below 0 dB, the way `eqtune preamp-auto` measures
    /// it: a log sweep up to Nyquist plus every band's own frequency.
    func peakGainDB(sampleRate: Double) -> Double {
        let top = Swift.min(20_000, sampleRate * 0.499)
        let sweep = (0...512).map { 20 * pow(top / 20, Double($0) / 512) }
        let points = sweep + map(\.hz).filter { $0 < sampleRate / 2 }
        return curve(at: points, sampleRate: sampleRate).reduce(0, Swift.max)
    }
}

extension Preset {
    /// How far loud audio would go past full scale (dB), or 0 when the preamp leaves room
    /// for the curve's biggest boost.
    func overloadDB(sampleRate: Double) -> Double {
        max(0, bands.peakGainDB(sampleRate: sampleRate) + preampDB)
    }
}

// MARK: - Plain-language guide

/// The spectrum the way engineers talk about it, so people who don't think in hertz can
/// tell what a band does.
enum FrequencyZone: CaseIterable, Sendable {
    case subBass, bass, lowMids, mids, upperMids, treble

    var range: ClosedRange<Double> {
        switch self {
        case .subBass: 20...60
        case .bass: 60...250
        case .lowMids: 250...500
        case .mids: 500...2000
        case .upperMids: 2000...6000
        case .treble: 6000...20_000
        }
    }

    var name: String {
        switch self {
        case .subBass: "Sub-bass"
        case .bass: "Bass"
        case .lowMids: "Low mids"
        case .mids: "Mids"
        case .upperMids: "Upper mids"
        case .treble: "Treble"
        }
    }

    var character: String {
        switch self {
        case .subBass: "Rumble you feel more than hear."
        case .bass: "Punch and warmth: kick drums and bass lines."
        case .lowMids: "The body of most instruments, and where mud builds up."
        case .mids: "The core of voices and instruments."
        case .upperMids: "Clarity and presence. Ears are most sensitive here."
        case .treble: "Sparkle, cymbals and air."
        }
    }

    var whenBoosted: String {
        switch self {
        case .subBass: "Adds weight. Small speakers can't play it, so boosting only uses up headroom."
        case .bass: "Fuller and punchier. Too much sounds boomy."
        case .lowMids: "Warmer and thicker, but it turns muddy quickly."
        case .mids: "Brings sound forward. Too much sounds honky or nasal."
        case .upperMids: "Clearer vocals and detail. Too much sounds harsh and tiring."
        case .treble: "Brighter and airier. Too much brings out hiss and sharp “s” sounds."
        }
    }

    var whenCut: String {
        switch self {
        case .subBass: "Tightens boomy rooms and headphones."
        case .bass: "Leaner and tighter."
        case .lowMids: "Clears up muddy, boxy sound."
        case .mids: "A scooped, more distant sound."
        case .upperMids: "Smoother and less fatiguing."
        case .treble: "Darker, softer and smoother."
        }
    }

    static func at(_ hz: Double) -> FrequencyZone {
        allCases.first { hz < $0.range.upperBound } ?? .treble
    }

    /// What a band at `band.hz` with `band.db` does, in one sentence.
    static func describe(_ band: Band) -> String {
        let zone = at(band.hz)
        let effect = abs(band.db) < 0.05 ? zone.character : band.db > 0 ? zone.whenBoosted : zone.whenCut
        return "\(zone.name): \(effect)"
    }
}

// MARK: - Tone controls

/// Bass and Treble, the two knobs every stereo has. Each one moves a shelf in the active
/// preset: the lowest low shelf or the highest high shelf, added when the preset has none.
enum Tone: CaseIterable, Sendable {
    case bass, treble

    static let range: ClosedRange<Double> = -12...12

    var name: String { self == .bass ? "Bass" : "Treble" }
    var kind: BandKind { self == .bass ? .lowShelf : .highShelf }
    /// Between the usual ISO band centers, so a new shelf rarely lands on an existing band.
    var defaultHz: Double { self == .bass ? 105 : 9000 }
}

extension Preset {
    /// The band `tone` moves: an existing shelf, or a flat new one that isn't there yet.
    func toneBand(_ tone: Tone) -> Band {
        let shelves = bands.filter { $0.kind == tone.kind }
        let existing = tone == .bass ? shelves.min { $0.hz < $1.hz } : shelves.max { $0.hz < $1.hz }
        return existing ?? Band(kind: tone.kind, hz: freeFrequency(near: tone.defaultHz), db: 0, q: 0.71)
    }

    /// The bands with `tone` set to `db`, as they'll be once eqtune applies it.
    func bands(settingTone tone: Tone, to db: Double) -> [Band] {
        var band = toneBand(tone)
        band.db = db
        return (bands.filter { !$0.sitsAt(band.hz) } + [band]).sorted { $0.hz < $1.hz }
    }

    /// `hz`, or if a band sits there, the nearest whole frequency around it that's free.
    /// eqtune would otherwise turn the band already there into the new one.
    func freeFrequency(near hz: Double) -> Double {
        let isFree = { (candidate: Double) in !bands.contains { $0.sitsAt(candidate) } }
        guard !isFree(hz) else { return hz }
        // 2% steps, alternating above and below: +2%, -2%, +4%, -4%…
        let nudged = (1..<40).map { (step: Int) -> Double in
            let offset = step % 2 == 1 ? (step + 1) / 2 : -step / 2
            return (hz * (1 + Double(offset) * 0.02)).rounded()
        }
        return nudged.first(where: isFree) ?? hz
    }
}
