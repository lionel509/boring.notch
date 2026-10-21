import Foundation

/// Why a cleanup did not replace the raw text. Recorded in `TakeReport` as a code.
enum CleanupSkip: String, Equatable {
    case none, unavailable, timeout, empty, guardRejected, error
}

/// Invariant I2: what gets pasted is the raw transcript or an LLM output that passed
/// `accept`. An answer, a refusal or a rewrite must be rejected.
enum CleanupGuard {
    /// Whole-output check. Rejects empty output, output longer than the raw text (plus a
    /// 10 % allowance), and output whose words mostly do not occur in the raw text.
    static func accept(raw: String, cleaned: String) -> Bool {
        let out = normalize(cleaned)
        guard !out.isEmpty else { return false }
        let rawWords = words(raw)
        let outWords = words(out)
        guard !outWords.isEmpty else { return false }
        if outWords.count > rawWords.count + max(1, rawWords.count / 10) { return false }
        let rawSet = Set(rawWords)
        let shared = outWords.filter { rawSet.contains($0) }.count
        return Double(shared) / Double(outWords.count) >= 0.6
    }

    /// Per-sentence check for streamed output: a sentence of three or more words needs at
    /// least half of its words inside the raw window it was aligned to.
    static func acceptSentence(sentence: String, rawWindow: String) -> Bool {
        let sentenceWords = words(sentence)
        guard sentenceWords.count >= 3 else { return true }
        let windowSet = Set(words(rawWindow))
        let shared = sentenceWords.filter { windowSet.contains($0) }.count
        return Double(shared) / Double(sentenceWords.count) >= 0.5
    }

    /// Strips wrapping quotes and a leading "Output:"-style label, then collapses whitespace.
    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["cleaned text:", "output:"] where s.lowercased().hasPrefix(label) {
            s = String(s.dropFirst(label.count))
            break
        }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
