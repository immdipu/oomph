import Foundation
import Observation
import os

/// Owns everything the UI shows. Every value is the latest eqtune output and nothing is
/// kept beyond it, so the UI can't drift from the daemon. All CLI work goes through
/// `client`, one call at a time.
@MainActor @Observable
final class EqtuneStore {
    /// Places that show live state. Polling runs only while at least one is open.
    enum Surface { case menu, editor, settings, onboarding }

    /// Why there is no status to show.
    enum Blocker: Equatable {
        case binaryMissing
        case notInstalled
        case unreachable(String)
        case unreadable(raw: String)
    }

    struct Failure: Equatable {
        var message: String
        /// eqtune's output, when it couldn't be parsed.
        var raw: String?

        init(message: String) {
            self.message = message
        }

        init(_ error: Error) {
            // eqtune prefixes errors with "error: " or "Error: "; the UI marks them already.
            let text = error.localizedDescription
            message = text.lowercased().hasPrefix("error: ") ? String(text.dropFirst(7)) : text
            // eqtune's advice is for its own CLI; Oomph has buttons for this.
            if message.hasPrefix("unsaved tuning changes are active") {
                message = "Save or discard your unsaved changes first."
            }
            if case EqtuneError.parseFailure(let output) = error { raw = output }
        }
    }

    /// eqtune's own presets; `eqtune reset` restores them.
    nonisolated static let shippedPresets = ["bright", "mellow", "pro"]

    private(set) var status: EqtuneStatus?
    private(set) var presets: [String] = []
    /// The active preset with exact values.
    private(set) var activePreset: Preset?
    /// Why `activePreset` couldn't be read.
    private(set) var presetProblem: Failure?
    private(set) var blocker: Blocker?
    /// A command is waiting or running.
    var isBusy: Bool { inFlight > 0 }
    private var inFlight = 0
    /// The last command that failed, shown until one succeeds.
    var failure: Failure?
    /// The last read kept earlier values because eqtune was slow to answer. They stay on
    /// screen for one poll rather than blanking every view, but nothing is built on them: the
    /// next command reads again first, and a second slow read in a row counts as unreachable.
    private var readIsStale = false
    /// Output-device UID → the preset to switch to when macOS starts playing through it.
    private(set) var devicePresets: [String: String]

    private let client: any EqtuneClient
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.dipu.eqtunebar", category: "store")
    private var surfaces: Set<Surface> = []
    private var poller: Task<Void, Never>?
    private var lane: Task<Void, Never>?
    /// Earlier tunings of each preset, for Undo and Redo.
    private var history: [String: History] = [:]

    private static let devicePresetsKey = "devicePresets"

    init(client: any EqtuneClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        devicePresets = defaults.dictionary(forKey: Self.devicePresetsKey) as? [String: String] ?? [:]
    }

    /// The EQ should be processing audio but isn't, and not because auto-off paused it on
    /// purpose. eqtune never clears `last error`, so that alone doesn't mean a problem now.
    var isFailing: Bool {
        guard let status, status.isOn, !status.engineRunning else { return false }
        return !["idle", "low-power"].contains(status.suspension ?? "")
    }

    /// Some preset has edits that aren't saved yet. eqtune refuses to import, clone, rename,
    /// delete or reset presets until they're saved or discarded.
    var hasUnsavedEdits: Bool { !(status?.dirtyPresets.isEmpty ?? true) }

    var canUndo: Bool { status.map { history[$0.preset]?.undo.isEmpty == false } ?? false }
    var canRedo: Bool { status.map { history[$0.preset]?.redo.isEmpty == false } ?? false }

    /// Why `name` can't be used for a new preset, or nil if it can. eqtune accepts shipped
    /// names as silent overwrites and rejects other existing ones, so Oomph refuses both;
    /// `none` would be unreadable in status's `dirty presets: none`.
    func nameProblem(_ name: String, allowActive: Bool) -> String? {
        if !Preset.isValidName(name) { return "Use 1–64 letters, digits, “-”, “_” or “.”." }
        if name == "none" { return "“none” is reserved." }
        if presets.contains(name), !(allowActive && name == status?.preset) {
            return "A preset named “\(name)” already exists."
        }
        // Library presets are known by name: one named like them would take on their title,
        // description and original tuning.
        if SoundLibrary.preset(name) != nil, !(allowActive && name == status?.preset) {
            return "“\(name)” is the name of a Sound Library preset."
        }
        return nil
    }

    /// `base` made into a valid preset name that isn't taken yet: `base`, `base-2`, `base-3`…
    func availableName(_ base: String) -> String {
        let cleaned = base.replacing(/[^A-Za-z0-9._-]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let stem = String((cleaned.isEmpty ? "preset" : cleaned).prefix(58))
        return ([stem] + (2...999).map { "\(stem)-\($0)" }).first { nameProblem($0, allowActive: false) == nil } ?? stem
    }

    // MARK: - Reading

    func setVisible(_ surface: Surface, _ visible: Bool) {
        if visible { surfaces.insert(surface) } else { surfaces.remove(surface) }
        poller?.cancel()
        poller = nil
        guard !surfaces.isEmpty else { return }
        // Refresh now (the new surface may need more data), then every 2 s.
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        await serially { await self.load() }
    }

    private func load() async {
        var kept = false
        defer { readIsStale = kept }
        do {
            let raw: String
            do {
                raw = try await client.run(["status"])
            } catch let error as EqtuneError where error.isDaemonBusy {
                raw = try await client.run(["status"]) // one more try before calling it unreachable
            }
            let status = try StatusParser.parse(raw)
            let presets = try PresetParser.parseList(try await client.run(["presets"]))
            // Read whether or not the menu or the equalizer is open, so either opens on the real
            // curve instead of a flat one that jumps a moment later.
            do {
                activePreset = try await exportedPreset(status.preset)
                presetProblem = nil
            } catch let error as EqtuneError where error.isDaemonBusy && activePreset?.name == status.preset && !readIsStale {
                kept = true // slow to answer: keep the last read once (see `readIsStale`)
            } catch {
                activePreset = nil
                presetProblem = Failure(error)
            }
            self.status = status
            self.presets = presets
            blocker = nil
        } catch let error as EqtuneError where error.isDaemonBusy && status != nil && !readIsStale {
            // Slow to answer (the engine restarting, say): keep the last read once rather than
            // blanking every view. Twice in a row, eqtune is treated as unreachable below.
            kept = true
            logger.info("eqtune was slow to answer; keeping the last read")
        } catch {
            status = nil
            presets = []
            activePreset = nil
            switch error {
            case EqtuneError.binaryNotFound: blocker = .binaryMissing
            case EqtuneError.parseFailure(let raw): blocker = .unreadable(raw: raw)
            default: blocker = EngineInstall.isInstalled ? .unreachable(Failure(error).message) : .notInstalled
            }
        }
    }

    /// A preset at full precision. `preset-show` rounds (10 Hz above 1 kHz, 0.1 dB, 0.01 Q)
    /// while eqtune matches bands within 0.5 Hz, so the editor works from `preset-export`.
    /// The daemon, not the CLI, writes the file.
    private func exportedPreset(_ name: String) async throws -> Preset {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await client.run(["preset-export", "--", name, file.path])
        return try PresetParser.parseExport(String(contentsOf: file, encoding: .utf8))
    }

    // MARK: - Switching and listening

    func setOn(_ on: Bool) async { await perform([on ? "on" : "off"]) }

    /// Turns the EQ off. Returns the presets with unsaved edits if `off` stopped at its
    /// save/discard prompt; the daemon has already restored native audio by then.
    func turnOff() async -> [String]? {
        guard let error = await command(["off"]) else { return nil }
        if case EqtuneError.nonZeroExit(_, let stderr) = error, stderr.contains("input closed before the prompt"),
           let dirty = status?.dirtyPresets, !dirty.isEmpty {
            return dirty
        }
        failure = Failure(error)
        return nil
    }

    /// Answers `off`'s save/discard prompt with "o": every preset keeps its edits.
    func saveEditsAndTurnOff() async { await perform(["off"], input: "o\n") }

    /// Drops every unsaved edit. `off` has no flag for that and switching presets keeps
    /// edits, so answer `off`'s own prompt with "d" (discard), like a person would.
    func discardEditsAndTurnOff() async { await perform(["off"], input: "d\n") }

    func selectPreset(_ name: String) async { await perform(["preset", "--", name]) }

    /// The preset just picked, to show as chosen until eqtune has switched to it or refused.
    /// A switch takes about half a second; without this a list jumps back to the old preset.
    private(set) var picked: String?

    /// Switches to `name`. Picks made while a switch runs (arrow keys, quick clicks) only
    /// change the target, so eqtune goes straight to the last one instead of through every
    /// preset passed on the way.
    func pick(_ name: String) {
        guard name != (picked ?? status?.preset) else { return }
        let switching = picked != nil
        picked = name
        guard !switching else { return }
        Task {
            while let target = picked, target != status?.preset {
                await selectPreset(target)
                // eqtune refused it: stop, unless something else was picked meanwhile.
                if status?.preset != target, picked == target { break }
            }
            picked = nil
        }
    }
    /// Only the switch changes, so only status is read back: a quick press and release keep
    /// up with the button instead of each waiting for a full reload.
    func setBypass(_ on: Bool) async {
        let error = await serially { () -> Error? in
            do {
                _ = try await self.client.run(["bypass", on ? "on" : "off"])
                self.status = try StatusParser.parse(try await self.client.run(["status"]))
                self.failure = nil // as in mutate: a failure shows until something works
                return nil
            } catch {
                return error
            }
        }
        if let error { failure = Failure(error) }
    }
    func setLimiter(_ on: Bool) async { await perform(["limiter", on ? "on" : "off"]) }
    func setAutoOffLowPower(_ on: Bool) async { await perform(["lowpower", on ? "on" : "off"]) }
    func setAutoOffIdle(_ on: Bool) async { await perform(["idle", on ? "on" : "off"]) }

    /// Picks a preset from Oomph's library: switches to it if it's already in eqtune,
    /// otherwise imports it first.
    func useLibraryPreset(_ item: LibraryPreset) async {
        if presets.contains(item.id) { await selectPreset(item.id) } else { await importPreset(item.preset) }
    }

    // MARK: - Tuning the active preset

    func setPreamp(_ db: Double, of preset: String) async {
        await perform(["preamp", Self.arg(db.clamped(to: Limits.preamp))], undoable: true, on: preset)
    }

    func autoPreamp(of preset: String) async { await perform(["preamp-auto"], undoable: true, on: preset) }

    func addBand(_ band: Band, to preset: String) async {
        await perform(Self.setCommand(band.clamped), undoable: true, on: preset)
    }

    /// Moves the Bass or Treble shelf of `name`, the active preset, to `db`, adding it if needed.
    func setTone(_ tone: Tone, to db: Double, of name: String) async {
        let error = await mutate(undoable: true) {
            guard let preset = self.activePreset, preset.name == name, name == self.status?.preset else { return }
            var band = preset.toneBand(tone)
            let target = db.clamped(to: Tone.range)
            // Already there. A missing shelf reads as flat, so letting go where it started on a
            // preset without one adds no flat shelf and doesn't mark the preset edited.
            guard band.db != target else { return }
            band.db = target
            _ = try await self.client.run(Self.setCommand(band))
        }
        if let error { failure = Failure(error) }
    }

    /// Changes one band of `preset` (`edited == nil` removes it). `shown` is the band as the
    /// editor showed it: fields the user didn't change keep eqtune's current value, and an edit
    /// that went stale while queued (another preset is active, the band moved away) is dropped.
    func editBand(_ shown: Band, of preset: String, to edited: Band?) async {
        let error = await mutate(undoable: true) {
            guard self.status?.preset == preset, let bands = self.activePreset?.bands,
                  let current = bands.first(where: { $0.sitsAt(shown.hz) }) else { return }
            let remove = ["band-rm", Self.arg(current.hz)]
            guard let edited else {
                _ = try await self.client.run(remove)
                return
            }
            let target = Band(kind: edited.kind == shown.kind ? current.kind : edited.kind,
                              hz: edited.hz == shown.hz ? current.hz : edited.hz.clamped(to: Limits.hz),
                              db: edited.db == shown.db ? current.db : edited.db.clamped(to: Limits.db),
                              q: edited.q == shown.q ? current.q : edited.q.clamped(to: Limits.q))
            guard !current.sitsAt(target.hz) else {
                _ = try await self.client.run(Self.setCommand(target)) // same frequency: eqtune updates the band in place
                return
            }
            // A band is identified by its frequency, so a move is add + remove. eqtune would
            // merge the band into any other one within 0.5 Hz of the target.
            if let other = bands.first(where: { $0.sitsAt(target.hz) }) {
                throw EditError(errorDescription: "Another band already sits at \(Self.arg(other.hz)) Hz.")
            }
            // Add first so a failure in between can't lose the band, unless the preset is full.
            for args in bands.count < Limits.maxBands ? [Self.setCommand(target), remove] : [remove, Self.setCommand(target)] {
                _ = try await self.client.run(args)
            }
        }
        if let error { failure = Failure(error) }
    }

    private struct EditError: LocalizedError {
        var errorDescription: String?
    }

    func undo(of preset: String) async { await travel(back: true, of: preset) }
    func redo(of preset: String) async { await travel(back: false, of: preset) }

    /// Puts `preset`, the active one, back to its tuning before (or after) the last edit, by
    /// sending the band commands that turn what eqtune has now into that tuning.
    private func travel(back: Bool, of preset: String) async {
        let error = await mutate {
            guard let current = self.activePreset, current.name == preset, preset == self.status?.preset,
                  let target = back ? self.history[current.name]?.undo.popLast() : self.history[current.name]?.redo.popLast()
            else { return }
            if back { self.history[current.name]?.redo.append(current) } else { self.history[current.name]?.undo.append(current) }
            for args in Self.commands(from: current, to: target) {
                _ = try await self.client.run(args)
            }
        }
        if let error { failure = Failure(error) }
    }

    /// The eqtune commands that turn `current` into `target`. Bands are matched by
    /// frequency, like eqtune does; removals go first so a full preset has room.
    static func commands(from current: Preset, to target: Preset) -> [[String]] {
        let removals = current.bands
            .filter { band in !target.bands.contains { $0.sitsAt(band.hz) } }
            .map { ["band-rm", arg($0.hz)] }
        let sets = target.bands
            .filter { band in current.bands.first { $0.sitsAt(band.hz) } != band }
            .map(setCommand)
        let preamp = current.preampDB == target.preampDB ? [] : [["preamp", arg(target.preampDB.clamped(to: Limits.preamp))]]
        return removals + sets + preamp
    }

    // MARK: - Saving and discarding

    /// Saves `preset`, the active one, under its own name or as `name`.
    func savePreset(_ preset: String, as name: String? = nil) async {
        await perform(["preset-save", "--", name ?? preset], on: preset)
    }

    /// Saves every preset with unsaved edits under its own name. `preset-save` only saves
    /// the active preset, so visit each of the others, then come back.
    func saveAll() async {
        let error = await mutate {
            guard let status = self.status else { return }
            for name in status.dirtyPresets where name != status.preset {
                _ = try await self.client.run(["preset", "--", name])
                _ = try await self.client.run(["preset-save", "--", name])
            }
            if status.dirtyPresets.contains(where: { $0 != status.preset }) {
                _ = try await self.client.run(["preset", "--", status.preset])
            }
            if status.activeIsDirty {
                _ = try await self.client.run(["preset-save", "--", status.preset])
            }
        }
        if let error { failure = Failure(error) }
    }

    /// Drops every unsaved edit. eqtune discards only through `off`'s own question, so
    /// answer it with "d", then turn the EQ back on if it was on.
    func discardAll() async {
        let error = await mutate {
            let wasOn = self.status?.isOn == true // in the lane: after earlier commands and a fresh read
            _ = try await self.client.run(["off"], input: "d\n")
            if wasOn { _ = try await self.client.run(["on"]) }
        }
        if let error { failure = Failure(error) }
    }

    // MARK: - Managing presets (eqtune requires no unsaved edits for these)

    /// Starts an empty (flat) preset and switches to it.
    func newPreset(named name: String) async {
        await importPreset(Preset(name: name, preampDB: 0, bands: []))
    }

    /// Adds `preset` to eqtune under its name and switches to it. The daemon reads the file
    /// itself, so Oomph hands it a temporary copy: eqtune has no permission of its own for
    /// folders like Downloads or Desktop.
    func importPreset(_ preset: Preset) async {
        let file = Self.temporaryFile()
        let error = await mutate {
            defer { try? FileManager.default.removeItem(at: file) }
            try preset.fileContents.write(to: file, atomically: true, encoding: .utf8)
            _ = try await self.client.run(["preset-import", "--", file.path, preset.name])
        }
        if let error { failure = Failure(error) }
    }

    /// Writes `name` as a shareable preset file. eqtune writes it to a temporary file and
    /// Oomph copies it into place, for the same permission reason as importing.
    func exportPreset(_ name: String, to destination: URL) async {
        let file = Self.temporaryFile()
        let error = await mutate {
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await self.client.run(["preset-export", "--", name, file.path])
            _ = try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
        }
        if let error { failure = Failure(error) }
    }

    /// Copies `name` as `copy` and switches to the copy.
    func duplicatePreset(_ name: String, as copy: String) async {
        await perform(["preset-clone", "--", name, copy])
    }

    func renamePreset(_ name: String, to newName: String) async {
        await perform(["preset-rename", "--", name, newName])
        guard failure == nil else { return }
        for (uid, preset) in devicePresets where preset == name { setDevicePreset(newName, for: uid) }
        history[newName] = history.removeValue(forKey: name)
    }

    /// Deletes `name`; if it was active, eqtune switches to the first remaining preset.
    func deletePreset(_ name: String) async {
        await perform(["preset-rm", "--", name])
        guard failure == nil else { return }
        for (uid, preset) in devicePresets where preset == name { setDevicePreset(nil, for: uid) }
        history[name] = nil
    }

    /// Puts one of eqtune's shipped presets back to its original tuning. `reset` asks
    /// whether to keep a copy of a changed one; Oomph asked already, so answer "r" (reset).
    func resetPreset(_ name: String) async {
        await perform(["reset", "--", name], input: "r\n")
        history[name] = nil
    }

    /// Puts a library preset back to Oomph's tuning and saves it. eqtune's `reset` knows only
    /// its own presets, so this edits the bands like a person would: unsaved edits to other
    /// presets are left alone.
    func resetLibraryPreset(_ item: LibraryPreset) async {
        let error = await mutate {
            // Without status it can't tell which preset the band commands would land on.
            guard let status = self.status else { throw EditError(errorDescription: "eqtune didn't answer, so nothing was reset.") }
            // It has to switch to edit the bands; afterwards, worked or not, go back to the one in use.
            let previous = status.preset == item.id ? nil : status.preset
            if previous != nil { _ = try await self.client.run(["preset", "--", item.id]) }
            do {
                let current = try await self.exportedPreset(item.id)
                for args in Self.commands(from: current, to: item.preset) {
                    _ = try await self.client.run(args)
                }
                _ = try await self.client.run(["preset-save", "--", item.id])
            } catch {
                if let previous { _ = try? await self.client.run(["preset", "--", previous]) }
                throw error
            }
            if let previous { _ = try await self.client.run(["preset", "--", previous]) }
        }
        if let error { failure = Failure(error) }
        history[item.id] = nil
    }

    // MARK: - Output devices

    /// Remembers `preset` for an output device (nil forgets it).
    func setDevicePreset(_ preset: String?, for uid: String) {
        devicePresets[uid] = preset
        defaults.set(devicePresets, forKey: Self.devicePresetsKey)
    }

    /// macOS switched outputs: switch to the preset chosen for that device, if any. A
    /// preset that no longer exists is forgotten instead of reported.
    func outputChanged(to uid: String) async {
        guard let name = devicePresets[uid] else { return }
        logger.info("output changed; switching to \(name, privacy: .public)")
        guard let error = await command(["preset", "--", name]) else { return }
        if Failure(error).message.hasPrefix("no such preset") {
            setDevicePreset(nil, for: uid)
        } else {
            failure = Failure(error)
        }
    }

    // MARK: - Engine install

    /// First run: install the LaunchAgent (it copies the bundled engine into Application
    /// Support), then start the EQ. Starting it makes macOS ask for audio-capture permission,
    /// and the daemon answers nobody until the user does, so `on` and the status read after it
    /// can time out; eqtune keeps the on-intent either way. Only a readable status with the EQ
    /// off counts as a failure; while the daemon is busy, status is nil and the caller waits.
    func installEngine() async {
        let error = await mutate(reread: false) {
            _ = try await self.client.run(["install"])
            await self.waitForDaemon()
            _ = try? await self.client.run(["on"])
        }
        if let error {
            failure = Failure(error)
        } else if let status, !status.isOn {
            failure = Failure(message: "The engine is installed, but the EQ didn't turn on. Try the switch in the menu.")
        }
    }

    /// Restarts a daemon that stopped answering: `install` rewrites its LaunchAgent and
    /// restarts it, keeping the EQ on or off as it was.
    func restartEngine() async {
        let error = await mutate(reread: false) {
            _ = try await self.client.run(["install"])
            await self.waitForDaemon()
        }
        if let error { failure = Failure(error) }
    }

    func uninstallEngine() async { await perform(["uninstall"]) }

    /// On launch, keep the installed daemon in step with the engine inside this build.
    /// The daemon never runs from the app (install copies it), so moving Oomph can't break
    /// it; what can go stale is its version after an Oomph update.
    func syncInstalledEngine() async {
        guard EngineInstall.isInstalled,
              let bundled = EqtuneBinary.version(of: EqtuneBinary.bundled) else { return }
        let installed = EngineInstall.daemonBinary.flatMap(EqtuneBinary.version(of:))
        guard installed != bundled else { return }
        logger.info("daemon is \(installed ?? "missing", privacy: .public), bundled engine is \(bundled, privacy: .public); reinstalling")
        _ = await mutate(reread: false) {
            _ = try await self.client.run(["install"])
            await self.waitForDaemon()
        }
    }

    /// `install` returns once launchd has started the daemon, which opens its socket a moment
    /// later; commands sent before that fail. Waits up to 5 s for it to answer.
    private func waitForDaemon() async {
        for _ in 0..<25 {
            if (try? await client.run(["status"])) != nil { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Plumbing

    /// `preset`: the command is for that preset, and is dropped if another one is active by
    /// the time its turn comes (it would change or overwrite the wrong one).
    private func perform(_ args: [String], input: String? = nil, undoable: Bool = false, on preset: String? = nil) async {
        let error = await mutate(undoable: undoable) {
            if let preset, self.status?.preset != preset { return }
            _ = try await self.client.run(args, input: input)
        }
        if let error { failure = Failure(error) }
    }

    /// Runs one command, then re-reads state. Returns the error instead of reporting it.
    private func command(_ args: [String], input: String? = nil) async -> Error? {
        await mutate { _ = try await self.client.run(args, input: input) }
    }

    /// Runs CLI work that changes state, then re-reads it, all in one turn of the lane.
    /// `undoable` work that changed the active preset's tuning becomes an Undo step.
    /// `reread: false` for work that reads no state (installing the engine), so it needn't wait
    /// for eqtune to answer a read first.
    private func mutate(undoable: Bool = false, reread: Bool = true, _ work: @escaping @MainActor () async throws -> Void) async -> Error? {
        inFlight += 1
        defer { inFlight -= 1 }
        return await serially {
            // The last read kept old values: a command built on them could hit the wrong band
            // or preset. Read again first; if eqtune is still too slow, the state is cleared and
            // commands for a preset or band find nothing to act on.
            if reread, self.readIsStale { await self.load() }
            let before = self.activePreset
            var error: Error?
            do { try await work() } catch let e { error = e }
            // The last failure shows until something works: a retry that fails the same way
            // leaves it in place instead of taking it away and bringing it back.
            if error == nil { self.failure = nil }
            await self.load()
            // A read kept now predates this command, and would pass for eqtune's answer to it.
            if self.readIsStale { await self.load() }
            if undoable, let before, let after = self.activePreset, before.name == after.name, before != after {
                self.history[before.name, default: History()].record(before)
            }
            return error
        }
    }

    /// Runs CLI work strictly in order, so a poll can't land between a command and its refresh.
    private func serially<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = lane
        let next = Task { @MainActor in
            await previous?.value
            return await work()
        }
        lane = Task { _ = await next.value }
        return await next.value
    }

    private struct History {
        var undo: [Preset] = []
        var redo: [Preset] = []

        mutating func record(_ preset: Preset) {
            undo.append(preset)
            if undo.count > 100 { undo.removeFirst() }
            redo.removeAll()
        }
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "oomph-\(UUID().uuidString).toml")
    }

    /// The command that adds `band`, or updates the band already at its frequency.
    private static func setCommand(_ band: Band) -> [String] {
        [band.kind.command, arg(band.hz), arg(band.db), arg(band.q)]
    }

    /// A number as eqtune's CLI parses it (Swift's shortest round-trip form, e.g. -3.5, 1000.0).
    /// Rounding a small cut gives −0, which eqtune would keep and write to files as "-0.0".
    private static func arg(_ value: Double) -> String { String(value == 0 ? 0 : value) }
}
