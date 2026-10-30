import Foundation

/// Parses eqtune's preset output (formats in Docs/cli-samples.md).
enum PresetParser {
    /// `eqtune ls`: one preset per line, the active one marked `* `, the others indented.
    static func parseList(_ raw: String) throws -> [String] {
        try raw.split(whereSeparator: \.isNewline).map { line in
            guard line.count > 2, line.hasPrefix("* ") || line.hasPrefix("  ") else {
                throw EqtuneError.parseFailure(raw: raw)
            }
            return String(line.dropFirst(2))
        }
    }

    /// `eqtune preset-show [name]`: a `name · preamp +x.x dB` header, then one band per line,
    /// e.g. `  low shelf   100 Hz   +5.0 dB  Q0.7`. Values are rounded for display (10 Hz above
    /// 1 kHz, 0.1 dB, 0.01 Q); `parseExport` has the exact ones.
    static func parseShow(_ raw: String) throws -> Preset {
        let failure = EqtuneError.parseFailure(raw: raw)
        var lines = raw.split(whereSeparator: \.isNewline)[...]
        guard let header = lines.popFirst(),
              let head = header.wholeMatch(of: /(?<name>.+) · preamp (?<preamp>[+-]?[\d.]+) dB/),
              let preamp = Double(head.preamp) else { throw failure }

        var bands: [Band] = []
        for line in lines where line.trimmingCharacters(in: .whitespaces) != "(no bands — flat)" {
            // Edit commands append "← changed" to one line; preset-show doesn't, but allow it.
            guard let m = line.firstMatch(of: /^\s+(?<kind>low shelf |high shelf )?\s*(?<hz>[\d.]+) (?<unit>k?Hz)\s+(?<db>[+-][\d.]+) dB\s+Q(?<q>[\d.]+)/),
                  let hz = Double(m.hz), let db = Double(m.db), let q = Double(m.q) else { throw failure }
            let kind: BandKind = switch m.kind {
            case "low shelf ": .lowShelf
            case "high shelf ": .highShelf
            default: .peaking
            }
            // kHz has at most 2 decimals, so whole Hz; rounding drops float noise (3.15 × 1000).
            bands.append(Band(kind: kind, hz: m.unit == "kHz" ? (hz * 1000).rounded() : hz, db: db, q: q))
        }
        return Preset(name: String(head.name), preampDB: preamp, bands: bands)
    }

    /// The TOML `eqtune preset-export <name> <path>` writes: `name`, `preamp_db`, then one
    /// `[[bands]]` table per band with `kind`, `freq`, `gain_db` and `q` at full precision.
    static func parseExport(_ raw: String) throws -> Preset {
        let failure = EqtuneError.parseFailure(raw: raw)
        var top: [String: String] = [:]
        var tables: [[String: String]] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line == "[[bands]]" { tables.append([:]); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if tables.isEmpty { top[key] = value } else { tables[tables.count - 1][key] = value }
        }
        let kinds: [String: BandKind] = ["peaking": .peaking, "low_shelf": .lowShelf, "high_shelf": .highShelf]
        guard let name = top["name"], let preamp = top["preamp_db"].flatMap(Double.init) else { throw failure }
        let bands = try tables.map { t in
            guard let kind = t["kind"].flatMap({ kinds[$0] }), let hz = t["freq"].flatMap(Double.init),
                  let db = t["gain_db"].flatMap(Double.init), let q = t["q"].flatMap(Double.init) else { throw failure }
            return Band(kind: kind, hz: hz, db: db, q: q)
        }
        return Preset(name: name, preampDB: preamp, bands: bands)
    }
}
