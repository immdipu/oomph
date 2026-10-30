import Foundation

/// Canned eqtune 0.7.1 output for SwiftUI previews and tests. Commands that change state
/// just succeed and are recorded in `calls`.
actor MockEqtuneClient: EqtuneClient {
    var outputs: [String: String] = [
        "status": """
            intent:        on
            engine:        running
            suspension:    none
            preset:        mellow
            preamp:        +0 dB
            bands:         4
            limiter:       true
            output UID:    BuiltInHeadphoneOutputDevice
            output name:   External Headphones
            output rate:   48000 Hz
            output stream: 48000 Hz, 2 ch, Float32, interleaved
            last error:    none
            retry:         idle
            bypass:        off
            dirty presets: mellow
            low power:     off
            auto-off LPM:  on
            auto-off idle: on
            """,
        "presets": "  bass\n  bright\n* mellow\n  pro\n",
        // `preset-export` writes this to the path it's given, like the daemon does.
        "preset-export": """
            name = "mellow"
            preamp_db = 0.0

            [[bands]]
            kind = "low_shelf"
            freq = 100.0
            gain_db = 4.0
            q = 0.70710677

            [[bands]]
            kind = "peaking"
            freq = 500.0
            gain_db = -3.0
            q = 1.41

            [[bands]]
            kind = "peaking"
            freq = 2000.0
            gain_db = -7.0
            q = 1.41

            [[bands]]
            kind = "high_shelf"
            freq = 10000.0
            gain_db = 2.0
            q = 0.7
            """,
    ]
    private(set) var calls: [[String]] = []

    func run(_ args: [String], input: String?) async throws -> String {
        calls.append(args)
        if args.first == "preset-export", let path = args.last {
            try outputs["preset-export", default: ""].write(toFile: path, atomically: true, encoding: .utf8)
            return ""
        }
        return outputs[args.joined(separator: " ")] ?? ""
    }
}
