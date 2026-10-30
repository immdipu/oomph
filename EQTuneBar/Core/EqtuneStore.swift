import Foundation
import Observation
import os

/// Owns everything the UI shows. Every value is the latest eqtune output and nothing is
/// kept beyond it, so the UI can't drift from the daemon. All CLI work goes through
/// `client`, one call at a time.
@MainActor @Observable
final class EqtuneStore {
    /// Places that show live state. Polling runs only while at least one is open.
    enum Surface { case menu, editor, settings }

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
            if case EqtuneError.parseFailure(let output) = error { raw = output }
        }
    }

    private(set) var status: EqtuneStatus?
    private(set) var presets: [String] = []
    /// The active preset with exact values, read only while the band editor is open.
    private(set) var activePreset: Preset?
    /// Why `activePreset` couldn't be read.
    private(set) var editorProblem: Failure?
    private(set) var blocker: Blocker?
    /// A command is running; controls disable themselves so nothing double-fires.
    var isBusy: Bool { inFlight > 0 }
    private var inFlight = 0
    /// The last command that failed, shown until the next one.
    var failure: Failure?

    private let client: any EqtuneClient
    private let logger = Logger(subsystem: "com.dipu.eqtunebar", category: "store")
    private var surfaces: Set<Surface> = []
    private var poller: Task<Void, Never>?
    private var lane: Task<Void, Never>?

    init(client: any EqtuneClient) {
        self.client = client
    }

    /// The EQ should be processing audio but isn't, and not because auto-off paused it on
    /// purpose. eqtune never clears `last error`, so that alone doesn't mean a problem now.
    var isFailing: Bool {
        guard let status, status.isOn, !status.engineRunning else { return false }
        return !["idle", "low-power"].contains(status.suspension ?? "")
    }

    /// Why `name` can't be used for a new preset, or nil if it can. eqtune accepts shipped
    /// names as silent overwrites and rejects other existing ones, so Oomph refuses both;
    /// `none` would be unreadable in status's `dirty presets: none`.
    func nameProblem(_ name: String, allowActive: Bool) -> String? {
        if !Preset.isValidName(name) { return "Use 1–64 letters, digits, “-”, “_” or “.”." }
        if name == "none" { return "“none” is reserved." }
        if presets.contains(name), !(allowActive && name == status?.preset) {
            return "A preset named “\(name)” already exists."
        }
        return nil
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
        do {
            let raw: String
            do {
                raw = try await client.run(["status"])
            } catch let error as EqtuneError where error.isDaemonBusy {
                raw = try await client.run(["status"]) // one more try before calling it unreachable
            }
            let status = try StatusParser.parse(raw)
            let presets = try PresetParser.parseList(try await client.run(["presets"]))
            if surfaces.contains(.editor) {
                do {
                    activePreset = try await exportedPreset(status.preset)
                    editorProblem = nil
                } catch {
                    activePreset = nil
                    editorProblem = Failure(error)
                }
            } else {
                activePreset = nil
            }
            self.status = status
            self.presets = presets
            blocker = nil
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
        let file = FileManager.default.temporaryDirectory.appending(path: "oomph-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await client.run(["preset-export", "--", name, file.path])
        return try PresetParser.parseExport(String(contentsOf: file, encoding: .utf8))
    }

    // MARK: - Commands

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

    /// Keeps the active preset's unsaved edits under `name`, then retries `off`.
    func saveEditsAndTurnOff(as name: String) async -> [String]? {
        if let error = await command(["preset-save", "--", name]) {
            failure = Failure(error)
            return nil
        }
        return await turnOff()
    }

    /// Drops every unsaved edit. `off` has no flag for that and switching presets keeps
    /// edits, so answer `off`'s own prompt with "d" (discard), like a person would.
    func discardEditsAndTurnOff() async {
        if let error = await command(["off"], input: "d\n") { failure = Failure(error) }
    }

    func selectPreset(_ name: String) async { await perform(["preset", "--", name]) }
    func setBypass(_ on: Bool) async { await perform(["bypass", on ? "on" : "off"]) }
    func setLimiter(_ on: Bool) async { await perform(["limiter", on ? "on" : "off"]) }
    func setAutoOffLowPower(_ on: Bool) async { await perform(["lowpower", on ? "on" : "off"]) }
    func setAutoOffIdle(_ on: Bool) async { await perform(["idle", on ? "on" : "off"]) }
    func setPreamp(_ db: Double) async { await perform(["preamp", Self.arg(db.clamped(to: Limits.preamp))]) }
    func autoPreamp() async { await perform(["preamp-auto"]) }
    func savePreset(as name: String) async { await perform(["preset-save", "--", name]) }

    func cloneActivePreset(to name: String) async {
        guard let active = status?.preset else { return }
        await perform(["preset-clone", "--", active, name])
    }

    func deleteActivePreset() async {
        guard let active = status?.preset else { return }
        await perform(["preset-rm", "--", active])
    }

    func addBand(_ band: Band) async {
        let band = band.clamped
        await perform([band.kind.command, Self.arg(band.hz), Self.arg(band.db), Self.arg(band.q)])
    }

    /// Changes one band of `preset` (`edited == nil` removes it). `shown` is the band as the
    /// editor showed it: fields the user didn't change keep eqtune's current value, and an edit
    /// that went stale while queued (another preset is active, the band moved away) is dropped.
    func editBand(_ shown: Band, of preset: String, to edited: Band?) async {
        let error = await mutate {
            guard self.status?.preset == preset, let bands = self.activePreset?.bands,
                  let current = bands.first(where: { abs($0.hz - shown.hz) < 0.5 }) else { return }
            let remove = ["band-rm", Self.arg(current.hz)]
            guard let edited else {
                _ = try await self.client.run(remove)
                return
            }
            let target = Band(kind: edited.kind == shown.kind ? current.kind : edited.kind,
                              hz: edited.hz == shown.hz ? current.hz : edited.hz.clamped(to: Limits.hz),
                              db: edited.db == shown.db ? current.db : edited.db.clamped(to: Limits.db),
                              q: edited.q == shown.q ? current.q : edited.q.clamped(to: Limits.q))
            let set = [target.kind.command, Self.arg(target.hz), Self.arg(target.db), Self.arg(target.q)]
            guard abs(target.hz - current.hz) >= 0.5 else {
                _ = try await self.client.run(set) // same frequency: eqtune updates the band in place
                return
            }
            // A band is identified by its frequency, so a move is add + remove. eqtune would
            // merge the band into any other one within 0.5 Hz of the target.
            if let other = bands.first(where: { abs($0.hz - target.hz) < 0.5 }) {
                throw EditError(errorDescription: "Another band already sits at \(Self.arg(other.hz)) Hz.")
            }
            // Add first so a failure in between can't lose the band, unless the preset is full.
            for args in bands.count < Limits.maxBands ? [set, remove] : [remove, set] {
                _ = try await self.client.run(args)
            }
        }
        if let error { failure = Failure(error) }
    }

    private struct EditError: LocalizedError {
        var errorDescription: String?
    }

    // MARK: - Engine install

    /// First run: install the LaunchAgent (it copies the bundled engine into Application
    /// Support), then start the EQ. While macOS still asks for audio-capture permission the
    /// engine can't start and `on` fails, but eqtune keeps the on-intent and retries, so only a
    /// missing intent counts as a failure.
    func installEngine() async {
        let error = await mutate {
            _ = try await self.client.run(["install"])
            await self.waitForDaemon()
            _ = try? await self.client.run(["on"])
        }
        if let error {
            failure = Failure(error)
        } else if status?.isOn != true {
            failure = Failure(message: "The engine is installed, but the EQ didn't turn on. Try the switch in the menu.")
        }
    }

    /// Restarts a daemon that stopped answering: `install` rewrites its LaunchAgent and
    /// restarts it, keeping the EQ on or off as it was.
    func restartEngine() async {
        let error = await mutate {
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
        _ = await mutate {
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

    private func perform(_ args: [String]) async {
        if let error = await command(args) { failure = Failure(error) }
    }

    /// Runs one command, then re-reads state. Returns the error instead of reporting it.
    private func command(_ args: [String], input: String? = nil) async -> Error? {
        await mutate { _ = try await self.client.run(args, input: input) }
    }

    /// Runs CLI work that changes state, then re-reads it, all in one turn of the lane.
    private func mutate(_ work: @escaping @MainActor () async throws -> Void) async -> Error? {
        inFlight += 1
        defer { inFlight -= 1 }
        failure = nil
        return await serially {
            var error: Error?
            do { try await work() } catch let e { error = e }
            await self.load()
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

    /// A number as eqtune's CLI parses it (Swift's shortest round-trip form, e.g. -3.5, 1000.0).
    private static func arg(_ value: Double) -> String { String(value) }
}
