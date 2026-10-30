import Foundation
import Testing
@testable import Oomph

struct BandResponseTests {
    let fs = 48_000.0

    @Test func peakingBandReadsItsGainAtCenterAndNothingFarAway() {
        let band = Band(kind: .peaking, hz: 1000, db: 6, q: 1)
        #expect(abs(band.gainDB(at: 1000, sampleRate: fs) - 6) < 0.01)
        #expect(abs(band.gainDB(at: 20, sampleRate: fs)) < 0.1)
        #expect(abs(band.gainDB(at: 20_000, sampleRate: fs)) < 0.1)
    }

    /// RBJ shelves with Q = 1/√2: full gain on their side, half of it (in dB) at the corner.
    @Test func shelvesReachTheirGainOnTheirSide() {
        let low = Band(kind: .lowShelf, hz: 100, db: 6, q: 0.7071)
        #expect(abs(low.gainDB(at: 100, sampleRate: fs) - 3) < 0.01)
        #expect(abs(low.gainDB(at: 20, sampleRate: fs) - 6) < 0.3)
        #expect(abs(low.gainDB(at: 10_000, sampleRate: fs)) < 0.01)
        let high = Band(kind: .highShelf, hz: 2000, db: -6, q: 0.7071)
        #expect(abs(high.gainDB(at: 2000, sampleRate: fs) + 3) < 0.01)
        #expect(abs(high.gainDB(at: 16_000, sampleRate: fs) + 6) < 0.3)
        #expect(abs(high.gainDB(at: 20, sampleRate: fs)) < 0.01)
    }

    /// The whole curve against `eqtune response --format json`, captured on the dev machine
    /// together with the exact preset it describes (`bass`: peaking bands plus a low shelf).
    @Test func matchesEqtunesOwnResponse() throws {
        struct Curve: Decodable {
            struct Point: Decodable { let frequencyHz: Double; let gainDb: Double }
            let sampleRateHz: Double
            let points: [Point]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let curve = try decoder.decode(Curve.self, from: Data(fixture("bass-response.json").utf8))
        let preset = try PresetParser.parseExport(fixture("bass-export.toml"))
        #expect(curve.points.count == 31)
        for point in curve.points {
            // eqtune's response includes the preamp; the chart's curve doesn't.
            let ours = preset.preampDB + preset.bands.gainDB(at: point.frequencyHz, sampleRate: curve.sampleRateHz)
            #expect(abs(ours - point.gainDb) < 0.05, "at \(point.frequencyHz) Hz")
        }
    }
}
