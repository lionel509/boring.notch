import Foundation

/// The words Apple's recognizer and the cloud transcript are told to spell exactly:
/// the list he types in Settings, then words he corrected often enough to trust.
enum PersonalDictionary {
    static let cap = 200
    static let promoteAt = 2

    /// Splits on commas and newlines, trims, drops empties, and dedupes case-insensitively
    /// keeping the first spelling and the original order.
    static func parseManual(_ text: String) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let word = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
        }
        return words
    }

    /// Manual words first, then learned words with at least `promoteAt` corrections
    /// (highest count first, then alphabetical), skipping any already listed. Capped at `cap`.
    static func words(manual: String, learned: [String: Int]) -> [String] {
        let manualWords = parseManual(manual)
        var seen = Set(manualWords.map { $0.lowercased() })
        let promoted = learned
            .filter { $0.value >= promoteAt }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.lowercased() < rhs.key.lowercased()
            }
            .map { $0.key }
            .filter { seen.insert($0.lowercased()).inserted }
        return Array((manualWords + promoted).prefix(cap))
    }

    /// Adds one count per candidate. A candidate matching an existing entry in any case bumps
    /// that entry and keeps its first spelling. Over `cap`, the lowest counts are dropped first, but never a
    /// word passed in this call, so a new word cannot be evicted on the call that learned it.
    static func learn(_ candidates: [String], into learned: inout [String: Int]) {
        var touched = Set<String>()
        for candidate in candidates {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            if let key = learned.keys.first(where: { $0.lowercased() == word.lowercased() }) {
                learned[key, default: 0] += 1
                touched.insert(key)
            } else {
                learned[word] = 1
                touched.insert(word)
            }
        }
        let excess = learned.count - cap
        guard excess > 0 else { return }
        let doomed = learned
            .filter { !touched.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
            }
            .prefix(excess)
            .map { $0.key }
        for key in doomed { learned[key] = nil }
    }
}
