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
}
