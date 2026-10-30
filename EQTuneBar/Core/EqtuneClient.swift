import Foundation

/// The one way Oomph talks to eqtune. Today that is the CLI (`ProcessEqtuneClient`);
/// a direct Unix-socket client can replace it without touching the UI.
protocol EqtuneClient: Sendable {
    /// Runs `eqtune <args>` and returns its stdout. `input` is written to stdin; without it
    /// stdin is /dev/null, so a prompt fails fast instead of hanging.
    func run(_ args: [String], input: String?) async throws -> String
}

extension EqtuneClient {
    func run(_ args: [String]) async throws -> String {
        try await run(args, input: nil)
    }
}

enum EqtuneError: Error, Equatable {
    case binaryNotFound
    case timeout
    case nonZeroExit(code: Int32, stderr: String)
    case parseFailure(raw: String)
}

extension EqtuneError: LocalizedError {
    /// The daemon handles one request at a time and can be busy for seconds while it
    /// (re)starts the audio engine; the CLI then gives up with a bare EAGAIN after 5 s.
    var isDaemonBusy: Bool {
        switch self {
        case .timeout: true
        case .nonZeroExit(_, let stderr): stderr.contains("os error 35")
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case _ where isDaemonBusy: "eqtune was busy and didn't answer in time; it may still finish."
        case .binaryNotFound: "The eqtune engine is missing."
        case .nonZeroExit(let code, let stderr):
            stderr.isEmpty ? "eqtune failed (exit code \(code))." : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case .parseFailure: "Oomph couldn't read eqtune's output."
        case .timeout: "eqtune didn't answer in time."
        }
    }
}
