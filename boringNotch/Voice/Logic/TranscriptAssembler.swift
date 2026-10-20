import Foundation

/// Joins the final speech segments into one line of text.
enum TranscriptAssembler {
    /// Trims every part, drops empties, and joins the words with single spaces.
    /// No leading, trailing or doubled whitespace; no characters are added or removed.
    static func join(_ parts: [String]) -> String {
        parts
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }
            .joined(separator: " ")
    }

    /// The text to join. The volatile tail (the transcriber's unconfirmed words) is
    /// added only when finalize did not finish, so a normal finalize never doubles it.
    static func parts(finals: [String], volatileTail: String, finalized: Bool) -> [String] {
        if finalized || volatileTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return finals
        }
        return finals + [volatileTail]
    }
}
