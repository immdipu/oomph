import Foundation

/// Parses `eqtune status`: one `label: value` line per field (format in Docs/cli-samples.md).
enum StatusParser {
    static func parse(_ raw: String) throws -> EqtuneStatus {
        var fields: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            // Values can contain colons (device names, errors); labels never do.
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let failure = EqtuneError.parseFailure(raw: raw)
        func text(_ label: String) throws -> String {
            guard let value = fields[label] else { throw failure }
            return value
        }
        /// nil when eqtune prints its placeholder (`none`, `(unavailable)`).
        func optional(_ label: String, none: String) throws -> String? {
            let value = try text(label)
            return value == none ? nil : value
        }
        func flag(_ label: String) throws -> Bool {
            switch try text(label) {
            case "on", "true": return true      // `limiter` prints true/false, the rest on/off
            case "off", "false": return false
            default: throw failure
            }
        }
        func number(_ label: String, unit: String) throws -> Double {
            guard let value = Double(try text(label).replacingOccurrences(of: unit, with: "")
                .trimmingCharacters(in: .whitespaces)) else { throw failure }
            return value
        }

        guard let bands = Int(try text("bands")) else { throw failure }
        let rate = try optional("output rate", none: "(unavailable)")
        let dirty = try text("dirty presets")
        return EqtuneStatus(
            isOn: try flag("intent"),
            engineRunning: try text("engine") == "running",
            suspension: try optional("suspension", none: "none"),
            preset: try text("preset"),
            preampDB: try number("preamp", unit: "dB"),
            bandCount: bands,
            limiter: try flag("limiter"),
            outputUID: try optional("output UID", none: "(unavailable)"),
            outputName: try optional("output name", none: "(unavailable)"),
            outputRateHz: rate.flatMap { Double($0.replacingOccurrences(of: " Hz", with: "")) },
            lastError: try optional("last error", none: "none"),
            bypass: try flag("bypass"),
            dirtyPresets: dirty == "none" ? [] : dirty.components(separatedBy: ", "),
            autoOffLowPower: try flag("auto-off LPM"),
            autoOffIdle: try flag("auto-off idle"))
    }
}
