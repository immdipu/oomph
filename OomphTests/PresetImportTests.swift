import AppKit
import Testing
@testable import Oomph

struct PresetImportTests {
    /// The shape of AutoEq's "ParametricEQ.txt" downloads.
    @Test func readsAnAutoEQCorrection() throws {
        let text = """
            Preamp: -6.4 dB
            Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
            Filter 2: ON PK Fc 2240 Hz Gain -3.1 dB Q 1.41
            Filter 3: ON HSC Fc 10000 Hz Gain -2.4 dB Q 0.70
            """
        let result = try PresetImport.read(text, name: "hd600")
        #expect(result.skipped.isEmpty)
        #expect(result.preset == Preset(name: "hd600", preampDB: -6.4, bands: [
            Band(kind: .lowShelf, hz: 105, db: 5.5, q: 0.7),
            Band(kind: .peaking, hz: 2240, db: -3.1, q: 1.41),
            Band(kind: .highShelf, hz: 10_000, db: -2.4, q: 0.7),
        ]))
    }

    @Test func leavesOutFiltersEqtuneCantPlay() throws {
        let text = """
            Preamp: -3 dB
            Filter 1: ON HP Fc 20 Hz
            Filter 2: OFF PK Fc 500 Hz Gain 9 dB Q 1
            Filter 3: ON PK Fc 1 kHz Gain 2 dB BW Oct 1
            """
        let result = try PresetImport.read(text, name: "x")
        #expect(result.skipped == ["HP 20 Hz"])
        #expect(result.preset.bands.count == 1)
        let band = try #require(result.preset.bands.first)
        #expect(band.hz == 1000)
        #expect(abs(band.q - 1.4142) < 0.001) // one octave
    }

    @Test func refusesGraphicEQAndEmptyFiles() {
        #expect(throws: PresetImport.Problem.graphicEQ) { try PresetImport.read("GraphicEQ: 20 -1; 30 -2", name: "x") }
        #expect(throws: PresetImport.Problem.nothingFound) { try PresetImport.read("hello", name: "x") }
    }

    /// Two filters on one frequency would be one band to eqtune; the second one moves over.
    @Test func keepsFiltersOnTheSameFrequencyApart() throws {
        let text = "Filter 1: ON PK Fc 100 Hz Gain 2 dB Q 1\nFilter 2: ON PK Fc 100 Hz Gain -1 dB Q 4\n"
        let bands = try PresetImport.read(text, name: "x").preset.bands
        #expect(bands.count == 2)
        #expect(Set(bands.map(\.hz)).count == 2)
    }

    @Test func eqtuneFilesKeepTheirValuesAndTakeTheNewName() throws {
        let preset = try PresetImport.read(fixture("bass-export.toml"), name: "my-bass").preset
        #expect(preset.name == "my-bass")
        #expect(preset.bands.count == 12)
        #expect(preset.preampDB == -9.10631)
    }

    /// What Oomph hands to `preset-import` reads back exactly, flat presets included.
    @Test func presetFilesRoundTrip() throws {
        let preset = try PresetParser.parseExport(fixture("bass-export.toml"))
        #expect(try PresetParser.parseExport(preset.fileContents) == preset)
        let flat = Preset(name: "flat", preampDB: 0, bands: [])
        #expect(flat.fileContents.contains("bands = []"))
        #expect(try PresetParser.parseExport(flat.fileContents) == flat)
    }

    @Test func namesComeFromTheFile() {
        #expect(PresetImport.suggestedName(for: URL(filePath: "/tmp/Sennheiser HD 600 ParametricEQ.txt")) == "Sennheiser HD 600")
        #expect(PresetImport.suggestedName(for: URL(filePath: "/tmp/warm.toml")) == "warm")
    }
}

struct SoundLibraryTests {
    @Test func everyPresetIsOneEqtuneAccepts() {
        let ids = SoundLibrary.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
        for item in SoundLibrary.presets {
            #expect(Preset.isValidName(item.id), "\(item.id)")
            #expect(!EqtuneStore.shippedPresets.contains(item.id), "\(item.id) would overwrite eqtune's own")
            #expect(!item.bands.isEmpty && item.bands.count <= Limits.maxBands)
            #expect(item.bands.allSatisfy { $0 == $0.clamped }, "\(item.id) is outside eqtune's limits")
            #expect(Limits.preamp.contains(item.preset.preampDB))
        }
    }

    /// Each one ships with enough headroom for its own boosts.
    @Test func noPresetCanClip() {
        for item in SoundLibrary.presets {
            #expect(item.preset.preampDB <= 0)
            #expect(item.preset.overloadDB(sampleRate: 48_000) < 0.01, "\(item.id)")
        }
    }

    @MainActor @Test func everySymbolExists() {
        for item in SoundLibrary.presets {
            #expect(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) != nil, "\(item.symbol)")
        }
    }

    /// In the sidebar eqtune's own presets say what they sound like, as the library's do.
    @MainActor @Test func eqtunesPresetsAreDescribed() {
        let store = EqtuneStore(client: MockEqtuneClient(), defaults: UserDefaults(suiteName: "oomph-tests-\(UUID())")!)
        for name in EqtuneStore.shippedPresets {
            #expect(store.summary(name) != store.summary("my-own-preset"), "\(name)")
        }
    }
}
