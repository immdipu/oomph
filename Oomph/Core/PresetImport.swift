import Foundation

/// Reads preset files people bring to Oomph: eqtune's own TOML exports, and the parametric
/// text Equalizer APO uses, which is how AutoEq (autoeq.app) publishes its headphone
/// corrections:
///
///     Preamp: -6.2 dB
///     Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
///     Filter 2: ON PK Fc 2240 Hz Gain -3.1 dB Q 1.41
enum PresetImport {
    struct Result: Equatable {
        var preset: Preset
        /// Filters eqtune has no equivalent for, left out of `preset`.
        var skipped: [String]
    }

    enum Problem: LocalizedError, Equatable {
        case graphicEQ, nothingFound, tooManyBands(Int)

        var errorDescription: String? {
            switch self {
            case .graphicEQ: "This is a graphic EQ file. Download the “Parametric EQ” version instead."
            case .nothingFound: "This file has no EQ filters Oomph can read."
            case .tooManyBands(let count): "This file has \(count) filters; a preset holds at most \(Limits.maxBands)."
            }
        }
    }

    static func read(_ text: String, name: String) throws -> Result {
        guard !text.contains("[[bands]]"), !text.contains("preamp_db") else {
            var preset = try PresetParser.parseExport(text)
            preset.name = name
            return Result(preset: preset, skipped: [])
        }
        return try parametric(text, name: name)
    }

    /// A name for a preset imported from `url`: its file name without AutoEq's suffix.
    static func suggestedName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacing(/[\s_-]*parametric\s*eq$/.ignoresCase(), with: "")
    }

    private static func parametric(_ text: String, name: String) throws -> Result {
        var preset = Preset(name: name, preampDB: 0, bands: [])
        var skipped: [String] = []
        var found = false
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.lowercased().hasPrefix("graphiceq:") { throw Problem.graphicEQ }
            if let m = line.wholeMatch(of: /preamp:\s*(?<db>[+-]?[\d.]+)\s*db/.ignoresCase()), let db = Double(m.db) {
                preset.preampDB = db.clamped(to: Limits.preamp)
                found = true
                continue
            }
            guard let m = line.wholeMatch(of: /filter\s*\d*\s*:\s*(?<state>on|off)\s+(?<type>[a-z]+)(?<rest>.*)/.ignoresCase()),
                  m.state.lowercased() == "on" else { continue }
            found = true
            let type = m.type.uppercased()
            let kind: BandKind? = switch type {
            case "PK", "PEQ", "MODAL": .peaking
            case "LS", "LSC": .lowShelf
            case "HS", "HSC": .highShelf
            default: nil
            }
            let fc = m.rest.firstMatch(of: /fc\s+(?<hz>[\d.]+)\s*(?<k>k?)hz/.ignoresCase())
                .flatMap { m in Double(m.hz).map { m.k.isEmpty ? $0 : $0 * 1000 } }
            let gain = m.rest.firstMatch(of: /gain\s+(?<db>[+-]?[\d.]+)\s*db/.ignoresCase()).flatMap { Double($0.db) }
            guard let kind, let fc, let gain else {
                skipped.append([type, fc.map { "\(Int($0)) Hz" }].compactMap { $0 }.joined(separator: " "))
                continue
            }
            let q = m.rest.firstMatch(of: /\bq\s+(?<q>[\d.]+)/.ignoresCase()).flatMap { Double($0.q) }
                ?? m.rest.firstMatch(of: /bw\s+oct\s+(?<bw>[\d.]+)/.ignoresCase()).flatMap { Double($0.bw) }.map(qForBandwidth)
                ?? (kind == .peaking ? 1 : 0.71)
            let band = Band(kind: kind, hz: fc, db: gain, q: q).clamped
            // Two filters on one frequency would be one band to eqtune.
            preset.bands.append(Band(kind: band.kind, hz: preset.freeFrequency(near: band.hz), db: band.db, q: band.q))
        }
        guard found else { throw Problem.nothingFound }
        guard preset.bands.count <= Limits.maxBands else { throw Problem.tooManyBands(preset.bands.count) }
        preset.bands.sort { $0.hz < $1.hz }
        return Result(preset: preset, skipped: skipped)
    }

    /// Q of a peaking filter `octaves` wide (the RBJ cookbook's relation).
    static func qForBandwidth(_ octaves: Double) -> Double {
        pow(2, octaves).squareRoot() / (pow(2, octaves) - 1)
    }
}
