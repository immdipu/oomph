import Testing
@testable import Oomph

/// Band edits address eqtune's bands by frequency, so a wrong command loses or merges a band.
@MainActor
struct EqtuneStoreTests {
    /// A store with the mock's `mellow` preset loaded the way the band editor sees it.
    /// Callers hide the editor again when done, which stops polling.
    private func editorStore() async -> (EqtuneStore, MockEqtuneClient) {
        let client = MockEqtuneClient()
        let store = EqtuneStore(client: client)
        store.setVisible(.editor, true)
        await store.refresh()
        return (store, client)
    }

    private func edits(_ client: MockEqtuneClient) async -> [[String]] {
        await client.calls.filter { !["status", "presets", "preset-export"].contains($0.first ?? "") }
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
    }
}
