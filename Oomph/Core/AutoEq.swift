import Foundation

/// AutoEq's catalog of measured headphone corrections (github.com/jaakkopasanen/AutoEq). Its
/// results index lists every model, and each result has a parametric EQ file in the
/// Equalizer APO format `PresetImport` reads.
enum AutoEq {
    struct Headphone: Identifiable, Hashable, Sendable {
        let name: String
        /// Who measured it, and on what: "oratory1990", "crinacle on 711".
        let source: String
        /// The result's folder under results/, percent-encoded as in the index.
        let path: String
        /// The name folded for search (lowercase letters and digits only) from each of its
        /// words on: "sennheiserhd600", "hd600", "600".
        let searchKeys: [String]

        init(name: String, source: String, path: String) {
            self.name = name
            self.source = source
            self.path = path
            let words = name.split { !$0.isLetter && !$0.isNumber }
            searchKeys = words.indices.map { AutoEq.searchKey(words[$0...].joined()) }
        }

        var id: String { path }
        var isInEar: Bool { path.contains("in-ear") || path.contains("earbud") }

        /// Each result's folder holds "<folder name> ParametricEQ.txt".
        var parametricEQ: URL {
            let folder = path.split(separator: "/").last.flatMap { String($0).removingPercentEncoding } ?? name
            return URL(string: results.absoluteString + path)!.appending(path: "\(folder) ParametricEQ.txt")
        }
    }

    static let results = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!

    /// Reads lines like `- [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990`.
    static func parseIndex(_ text: String) -> [Headphone] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            // Folders can hold parentheses, so the folder runs to the last ") by ".
            guard line.hasPrefix("- ["), let link = line.range(of: "](./"),
                  let by = line.range(of: ") by ", options: .backwards), link.upperBound <= by.lowerBound else { return nil }
            return Headphone(name: String(line[line.index(line.startIndex, offsetBy: 3)..<link.lowerBound]),
                             source: String(line[by.upperBound...]),
                             path: String(line[link.upperBound..<by.lowerBound]))
        }
    }

    /// The headphones whose name holds every word of `query`, in any order and ignoring case,
    /// accents, spaces and punctuation, so "hd600" finds "HD 600". Names whose words start the
    /// way the query's do come first: "hd600" lists "HD 600" before "AH-D600".
    static func search(_ query: String, in headphones: [Headphone]) -> [Headphone] {
        let words = query.split(whereSeparator: \.isWhitespace).map { searchKey(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return headphones }
        let matches = headphones.filter { headphone in words.allSatisfy { headphone.searchKeys.first?.contains($0) == true } }
        func startsWords(_ headphone: Headphone) -> Bool {
            words.allSatisfy { word in headphone.searchKeys.contains { $0.hasPrefix(word) } }
        }
        return matches.filter(startsWords) + matches.filter { !startsWords($0) }
    }

    private static func searchKey(_ text: String) -> String {
        String(String.UnicodeScalarView(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// The index, downloaded at most once a day and kept for when the Mac is offline.
    static func loadIndex() async throws -> [Headphone] {
        let folder = URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Oomph")
        let cache = folder.appending(path: "AutoEq-INDEX.md")
        let saved = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let saved, saved.timeIntervalSinceNow > -86_400, let text = try? String(contentsOf: cache, encoding: .utf8) {
            return parseIndex(text)
        }
        do {
            let text = try await download(results.appending(path: "INDEX.md"))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? text.write(to: cache, atomically: true, encoding: .utf8)
            return parseIndex(text)
        } catch {
            guard let text = try? String(contentsOf: cache, encoding: .utf8) else { throw error }
            return parseIndex(text)
        }
    }

    static func download(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }
}
