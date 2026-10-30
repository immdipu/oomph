import Testing
@testable import Oomph

struct PresetParserTests {
    @Test func parsesPresetList() throws {
        #expect(try PresetParser.parseList(fixture("ls.txt")) == ["bass", "bright", "mellow", "pro"])
    }

    @Test func rejectsAnUnexpectedList() {
        #expect(throws: EqtuneError.self) { try PresetParser.parseList("presets: bass, bright\n") }
    }

    /// The machine's own `bass` preset: peaking bands, a low shelf, Hz and kHz.
    @Test func parsesPresetShow() throws {
        let preset = try PresetParser.parseShow(fixture("preset-show-bass.txt"))
        #expect(preset.name == "bass")
        #expect(preset.preampDB == -9.1)
        #expect(preset.bands.count == 12)
        #expect(preset.bands[0] == Band(kind: .peaking, hz: 32, db: 3, q: 1.41))
        #expect(preset.bands[1] == Band(kind: .peaking, hz: 60, db: 2, q: 1))
        #expect(preset.bands[3] == Band(kind: .lowShelf, hz: 100, db: 5, q: 0.7))
        #expect(preset.bands[7] == Band(kind: .peaking, hz: 1000, db: -4, q: 1.41))
        #expect(preset.bands[11] == Band(kind: .peaking, hz: 16_000, db: 2, q: 1.41))
    }

    @Test func parsesFractionalFrequencies() throws {
        let preset = try PresetParser.parseShow(fixture("preset-show-pro.txt"))
        #expect(preset.bands.count == 28)
        #expect(preset.bands.map(\.hz).contains(31.5))
        #expect(preset.bands.map(\.hz).contains(1250))
        #expect(preset.bands.map(\.hz).contains(3150))
        #expect(preset.bands.first { $0.hz == 125 }?.db == -15)
    }

    @Test func parsesHighShelfAndFlatPresets() throws {
        let shelf = try PresetParser.parseShow("air · preamp -2.5 dB\n  high shelf    10 kHz   +2.0 dB  Q0.7\n")
        #expect(shelf.bands == [Band(kind: .highShelf, hz: 10_000, db: 2, q: 0.7)])
        #expect(shelf.preampDB == -2.5)
        let flat = try PresetParser.parseShow("flat · preamp +0.0 dB\n  (no bands — flat)\n")
        #expect(flat.bands.isEmpty)
    }

    @Test func rejectsAnUnexpectedBandLine() {
        let raw = "bass · preamp -9.1 dB\n  32 Hz boost 3\n"
        #expect(throws: EqtuneError.parseFailure(raw: raw)) { try PresetParser.parseShow(raw) }
    }

    /// Tests run inside Oomph.app, so this is the engine the build script bundled. The launch
    /// check compares this version with the installed daemon's.
    @Test func bundledEngineIsInTheAppWithItsVersion() {
        #expect(EqtuneBinary.resolve() == EqtuneBinary.bundled)
        #expect(EqtuneBinary.version(of: EqtuneBinary.bundled) == "0.7.1")
    }

    /// `preset-export` keeps full precision, which `preset-show` rounds away.
    @Test func parsesExportedPreset() throws {
        let preset = try PresetParser.parseExport(fixture("bass-export.toml"))
        #expect(preset.name == "bass")
        #expect(preset.preampDB == -9.10631)
        #expect(preset.bands.count == 12)
        #expect(preset.bands[3] == Band(kind: .lowShelf, hz: 100, db: 5, q: 0.7))
        #expect(preset.bands[7] == Band(kind: .peaking, hz: 1000, db: -4, q: 1.41))
    }
}
