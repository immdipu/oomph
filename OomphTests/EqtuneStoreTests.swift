import Foundation
import Testing
@testable import Oomph

/// Band edits address eqtune's bands by frequency, so a wrong command loses or merges a band.
@MainActor
struct EqtuneStoreTests {
    /// A store with the mock's `mellow` preset loaded the way the equalizer sees it.
    /// Callers hide the editor again when done, which stops polling.
    private func editorStore() async -> (EqtuneStore, MockEqtuneClient) {
        let client = MockEqtuneClient()
        let store = EqtuneStore(client: client, defaults: UserDefaults(suiteName: "oomph-tests-\(UUID())")!)
        store.setVisible(.editor, true)
        // The poller's first refresh may still be queued; this one runs after it, so a test
        // that changes the mock's output next can't have it read early.
        await store.refresh()
        await store.refresh()
        return (store, client)
    }

    private func edits(_ client: MockEqtuneClient) async -> [[String]] {
        await client.calls.filter { !["status", "presets", "preset-export"].contains($0.first ?? "") }
    }

    /// The mock's `mellow` export with the 500 Hz band at `db`.
    private func mellow(midCut db: Double) async throws -> String {
        try await fixtureFromMock().replacingOccurrences(of: "gain_db = -3.0", with: "gain_db = \(db)")
    }

    private func fixtureFromMock() async throws -> String {
        try #require(await MockEqtuneClient().outputs["preset-export"])
    }

    @Test func editKeepsUntouchedFieldsExact() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        let shelf = try #require(store.activePreset?.bands.first)
        await store.editBand(shelf, of: "mellow", to: Band(kind: shelf.kind, hz: shelf.hz, db: 5, q: shelf.q))
        // Q stays 0.70710677 as exported, not a rounded 0.71.
        #expect(await edits(client) == [["low-shelf", "100.0", "5.0", "0.70710677"]])
    }

    @Test func moveAddsBeforeRemoving() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        let band = try #require(store.activePreset?.bands.first { $0.hz == 500 })
        await store.editBand(band, of: "mellow", to: Band(kind: .peaking, hz: 630, db: -3, q: 1.41))
        #expect(await edits(client) == [["band", "630.0", "-3.0", "1.41"], ["band-rm", "500.0"]])
    }

    @Test func moveOntoAnotherBandIsRefused() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        let band = try #require(store.activePreset?.bands.first { $0.hz == 500 })
        await store.editBand(band, of: "mellow", to: Band(kind: .peaking, hz: 2000.3, db: -3, q: 1.41))
        #expect(await edits(client).isEmpty)
        #expect(store.failure?.message == "Another band already sits at 2000.0 Hz.")
    }

    @Test func staleEditsAreDropped() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        let band = try #require(store.activePreset?.bands.first)
        await store.editBand(band, of: "bass", to: nil) // another preset is active now
        await store.editBand(Band(kind: .peaking, hz: 700, db: 0, q: 1), of: "mellow", to: nil) // band gone
        #expect(await edits(client).isEmpty)
    }

    @Test func newPresetNamesAvoidExistingAndReservedOnes() async {
        let (store, _) = await editorStore()
        defer { store.setVisible(.editor, false) }
        #expect(store.nameProblem("my-mix_2.v1", allowActive: false) == nil)
        #expect(store.nameProblem("mellow", allowActive: true) == nil) // the active one: save in place
        #expect(store.nameProblem("mellow", allowActive: false) != nil)
        #expect(store.nameProblem("bright", allowActive: true) != nil) // shipped: would overwrite
        #expect(store.nameProblem("none", allowActive: true) != nil)
        #expect(store.nameProblem("has space", allowActive: true) != nil)
        #expect(store.availableName("mellow") == "mellow-2")
        #expect(store.availableName("Sennheiser HD 600") == "Sennheiser-HD-600")
        #expect(store.availableName("  ") == "preset")
    }

    /// Undo sends the band commands that turn eqtune's tuning back into the earlier one.
    /// The mock doesn't apply commands, so each step first sets what eqtune will report.
    @Test func undoAndRedoRestoreTheTuning() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        let band = try #require(store.activePreset?.bands.first { $0.hz == 500 })
        let original = try await fixtureFromMock(), edited = try await mellow(midCut: -1.0)
        await client.setOutput(edited, for: "preset-export")
        await store.editBand(band, of: "mellow", to: Band(kind: .peaking, hz: 500, db: -1, q: 1.41))
        #expect(store.canUndo && !store.canRedo)
        await client.setOutput(original, for: "preset-export")
        await store.undo()
        #expect(await edits(client).suffix(1) == [["band", "500.0", "-3.0", "1.41"]])
        #expect(!store.canUndo && store.canRedo)
        await client.setOutput(edited, for: "preset-export")
        await store.redo()
        #expect(await edits(client).suffix(1) == [["band", "500.0", "-1.0", "1.41"]])
        #expect(store.canUndo && !store.canRedo)
    }

    @Test func commandsRemoveSetAndLevel() {
        let current = Preset(name: "p", preampDB: 0, bands: [
            Band(kind: .peaking, hz: 100, db: 3, q: 1), Band(kind: .peaking, hz: 1000, db: 2, q: 1),
        ])
        let target = Preset(name: "p", preampDB: -3, bands: [
            Band(kind: .peaking, hz: 100, db: 3, q: 1), Band(kind: .highShelf, hz: 8000, db: 3, q: 0.71),
        ])
        #expect(EqtuneStore.commands(from: current, to: target) == [
            ["band-rm", "1000.0"], ["high-shelf", "8000.0", "3.0", "0.71"], ["preamp", "-3.0"],
        ])
        #expect(EqtuneStore.commands(from: current, to: current).isEmpty)
    }

    /// Bass moves the preset's low shelf; Treble adds a high shelf when there is none.
    @Test func toneControlsMoveOrAddShelves() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        await store.setTone(.bass, to: 6)
        #expect(await edits(client).last == ["low-shelf", "100.0", "6.0", "0.70710677"])
        let preset = try #require(store.activePreset)
        let treble = Preset(name: "t", preampDB: 0, bands: [Band(kind: .peaking, hz: 9000, db: 1, q: 1)]).toneBand(.treble)
        #expect(treble.kind == .highShelf && treble.hz != 9000) // moved off the existing band
        #expect(preset.toneBand(.treble).hz == 10_000) // mellow already has one
    }

    /// `preset-save` saves only the active preset, so the others are visited one by one.
    @Test func saveAllVisitsEveryEditedPreset() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        await client.setOutput(try fixture("status-dirty.txt").replacingOccurrences(of: "preset:        bass", with: "preset:        mellow"),
                               for: "status")
        await store.refresh()
        await store.saveAll()
        #expect(await edits(client) == [
            ["preset", "--", "bass"], ["preset-save", "--", "bass"],
            ["preset", "--", "my-mix.v2"], ["preset-save", "--", "my-mix.v2"],
            ["preset", "--", "mellow"],
        ])
    }

    /// eqtune discards only through `off`'s prompt, so the EQ comes back on afterwards.
    @Test func discardAllAnswersOffAndTurnsBackOn() async {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        await store.discardAll()
        #expect(await edits(client) == [["off"], ["on"]])
        #expect(await client.inputs[client.calls.firstIndex(of: ["off"])!] == "d\n")
    }

    @Test func importsGoThroughATemporaryFile() async throws {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        let item = try #require(SoundLibrary.preset("bass-boost"))
        await store.useLibraryPreset(item)
        let call = try #require(await edits(client).last)
        #expect(call.prefix(2) == ["preset-import", "--"] && call.last == "bass-boost")
        #expect(try PresetParser.parseExport(#require(await client.imported.last)) == item.preset)
        #expect(!FileManager.default.fileExists(atPath: call[2]))
    }

    @Test func outputChangesSwitchToTheDevicesPreset() async {
        let (store, client) = await editorStore()
        defer { store.setVisible(.editor, false) }
        store.setDevicePreset("bass", for: "AirPods-UID")
        await store.outputChanged(to: "Speakers-UID")
        await store.outputChanged(to: "AirPods-UID")
        #expect(await edits(client) == [["preset", "--", "bass"]])
        store.setDevicePreset(nil, for: "AirPods-UID")
        #expect(store.devicePresets.isEmpty)
    }
}

struct ToneAndHeadroomTests {
    @Test func freeFrequencyStepsAroundTakenOnes() {
        let preset = Preset(name: "p", preampDB: 0, bands: [Band(kind: .peaking, hz: 100, db: 0, q: 1)])
        #expect(preset.freeFrequency(near: 250) == 250)
        #expect(preset.freeFrequency(near: 31.5) == 31.5) // free frequencies keep their decimals
        #expect(preset.freeFrequency(near: 100) == 102)
    }

    @Test func overloadIsTheBoostThePreampDoesntCover() {
        let boost = [Band(kind: .peaking, hz: 1000, db: 6, q: 1)]
        #expect(abs(Preset(name: "p", preampDB: 0, bands: boost).overloadDB(sampleRate: 48_000) - 6) < 0.05)
        #expect(Preset(name: "p", preampDB: -6, bands: boost).overloadDB(sampleRate: 48_000) < 0.05)
        #expect(Preset(name: "p", preampDB: 0, bands: [Band(kind: .peaking, hz: 1000, db: -6, q: 1)]).overloadDB(sampleRate: 48_000) == 0)
    }

    @Test func settingAToneReplacesItsShelf() {
        let preset = Preset(name: "p", preampDB: 0, bands: [Band(kind: .lowShelf, hz: 80, db: 2, q: 0.7)])
        #expect(preset.bands(settingTone: .bass, to: -4) == [Band(kind: .lowShelf, hz: 80, db: -4, q: 0.7)])
        #expect(preset.bands(settingTone: .treble, to: 3).last == Band(kind: .highShelf, hz: 9000, db: 3, q: 0.71))
    }

    @Test func zonesDescribeWhatABandDoes() {
        #expect(FrequencyZone.at(40) == .subBass)
        #expect(FrequencyZone.at(3000) == .upperMids)
        #expect(FrequencyZone.at(20_000) == .treble)
        #expect(FrequencyZone.describe(Band(kind: .peaking, hz: 300, db: -3, q: 1)) == "Low mids: Clears up muddy, boxy sound.")
    }
}
