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
    var outputName: String?
    var outputRateHz: Double?
    var lastError: String?
    var bypass: Bool
    var dirtyPresets: [String]
    var autoOffLowPower: Bool
    var autoOffIdle: Bool
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

    var label: String {
        switch self {
        case .peaking: "Peak"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
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

extension Band {
    /// This band's gain in dB at `frequency`, from the same RBJ cookbook biquads eqtune uses
    /// (shelves take Q directly, no slope parameter).
    func gainDB(at frequency: Double, sampleRate fs: Double) -> Double {
        let a = pow(10, db / 40)
        let w0 = 2 * .pi * hz / fs
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let beta = 2 * a.squareRoot() * alpha
        let (b, d): ([Double], [Double]) = switch kind {
        case .peaking:
            ([1 + alpha * a, -2 * c, 1 - alpha * a],
             [1 + alpha / a, -2 * c, 1 - alpha / a])
        case .lowShelf:
            ([a * ((a + 1) - (a - 1) * c + beta), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - beta)],
             [(a + 1) + (a - 1) * c + beta, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - beta])
        case .highShelf:
            ([a * ((a + 1) + (a - 1) * c + beta), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - beta)],
             [(a + 1) - (a - 1) * c + beta, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - beta])
        }
        // |H(e^jw)|² for numerator and denominator.
        let w = 2 * .pi * frequency / fs
        func power(_ k: [Double]) -> Double {
            let re = k[0] + k[1] * cos(w) + k[2] * cos(2 * w)
            let im = k[1] * sin(w) + k[2] * sin(2 * w)
            return re * re + im * im
        }
        return 10 * log10(power(b) / power(d))
    }
}

extension [Band] {
    /// The EQ curve at `frequency`: every band's gain summed in dB (preamp not included).
    func gainDB(at frequency: Double, sampleRate: Double) -> Double {
        reduce(0) { $0 + $1.gainDB(at: frequency, sampleRate: sampleRate) }
    }
}
