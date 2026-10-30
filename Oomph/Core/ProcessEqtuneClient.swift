import Foundation
import os

/// Runs the eqtune CLI. Every call is logged with its exit code.
actor ProcessEqtuneClient: EqtuneClient {
    private let logger = Logger(subsystem: "com.dipu.eqtunebar", category: "cli")

    func run(_ args: [String], input: String?) async throws -> String {
        let command = (["eqtune"] + args).joined(separator: " ")
        guard let binary = EqtuneBinary.resolve() else {
            logger.error("\(command, privacy: .public): binary not found")
            throw EqtuneError.binaryNotFound
        }
        // install/uninstall drive launchctl and wait for the daemon to settle.
        let timeout: TimeInterval = ["install", "uninstall"].contains(args.first) ? 30 : 5
        let result: (code: Int32, stdout: String, stderr: String)
        do {
            result = try await Self.execute(binary, args, input: input, timeout: timeout)
        } catch {
            logger.error("\(command, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard result.code == 0 else {
            logger.error("\(command, privacy: .public) → exit \(result.code): \(result.stderr, privacy: .public)")
            throw EqtuneError.nonZeroExit(code: result.code, stderr: result.stderr)
        }
        logger.info("\(command, privacy: .public) → exit 0")
        return result.stdout
    }

    private static func execute(_ binary: URL, _ args: [String], input: String?, timeout: TimeInterval) async throws -> (code: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try executeBlocking(binary, args, input: input, timeout: timeout) })
            }
        }
    }

    private static func executeBlocking(_ binary: URL, _ args: [String], input: String?, timeout: TimeInterval) throws -> (code: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if let stdin, let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw EqtuneError.timeout
        }
        // ponytail: pipes are read after exit, which is fine for eqtune's sub-KB output;
        // drain them while it runs if a command ever prints more than the 16 KB pipe buffer.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

/// Where the eqtune executable lives.
enum EqtuneBinary {
    /// UserDefaults key of the path typed in Settings.
    static let overrideKey = "eqtunePath"

    /// The engine built from Vendor/eqtune and shipped inside Oomph.app.
    static var bundled: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/eqtune") }

    /// Bundled helper → path from Settings → ~/.cargo/bin, then the usual Homebrew/manual spots.
    static func resolve(includingCustom: Bool = true) -> URL? {
        let custom = UserDefaults.standard.string(forKey: overrideKey).flatMap { path in
            path.isEmpty || !includingCustom ? nil : URL(filePath: (path as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [bundled, custom, home.appending(path: ".cargo/bin/eqtune"),
                URL(filePath: "/usr/local/bin/eqtune"), URL(filePath: "/opt/homebrew/bin/eqtune")]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The version in a binary's embedded Info.plist (eqtune links one in), without running it.
    static func version(of binary: URL) -> String? {
        let info = CFBundleCopyInfoDictionaryForURL(binary as CFURL) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }
}

/// The LaunchAgent `eqtune install` writes. It points at a copy of the binary in
/// ~/Library/Application Support/eqtune, never at the app, so moving Oomph can't break it.
enum EngineInstall {
    static var launchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/app.eqtune.daemon.plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: launchAgent.path) }

    /// The binary the LaunchAgent starts.
    static var daemonBinary: URL? {
        guard let data = try? Data(contentsOf: launchAgent),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = (plist["ProgramArguments"] as? [String])?.first else { return nil }
        return URL(filePath: path)
    }
}
