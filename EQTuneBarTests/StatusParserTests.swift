import Foundation
import Testing
@testable import Oomph

/// A file from EQTuneBarTests/Fixtures, which Xcode copies into the test bundle.
func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle(for: FixtureToken.self).url(forResource: name, withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
}

private final class FixtureToken {}

struct StatusParserTests {
    /// `eqtune status` exactly as eqtune 0.7.1 printed it on the dev machine.
    @Test func parsesRealStatus() throws {
        let status = try StatusParser.parse(fixture("status-on.txt"))
        #expect(status == EqtuneStatus(
            isOn: true, engineRunning: true, suspension: nil, preset: "bass", preampDB: -9.10631,
            bandCount: 12, limiter: true, outputName: "External Headphones", outputRateHz: 48_000,
            lastError: nil, bypass: false, dirtyPresets: [], autoOffLowPower: true, autoOffIdle: true))
    }

    @Test func parsesLastErrorAndUnavailableOutput() throws {
        let status = try StatusParser.parse(fixture("status-error.txt"))
        #expect(status.isOn)
        #expect(!status.engineRunning)
        #expect(status.suspension == "recovering")
        #expect(status.lastError == "could not start the audio tap: AudioHardwareCreateProcessTap failed (OSStatus 560947818)")
        #expect(status.outputName == nil)
        #expect(status.outputRateHz == nil)
        #expect(status.preampDB == -8)
        #expect(!status.limiter)
    }

    @Test func parsesDirtyPresets() throws {
        let status = try StatusParser.parse(fixture("status-dirty.txt"))
        #expect(status.dirtyPresets == ["bass", "my-mix.v2"])
        #expect(!status.isOn)
        #expect(status.preampDB == 0)
        #expect(status.bypass)
        #expect(status.suspension == "user-off")
        #expect(!status.autoOffLowPower)
    }

    @Test func keepsRawTextWhenTheFormatChanges() {
        let raw = "intent: maybe\nengine: running\n"
        #expect(throws: EqtuneError.parseFailure(raw: raw)) { try StatusParser.parse(raw) }
    }
}
