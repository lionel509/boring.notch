import Foundation

enum GhostTextPrompt {
    static let instructions = "You finish the user's sentence. Reply with only the next few words that naturally continue the text, at most 12 words, in the same language and tone. No quotes, no explanation, never repeat the given text."

    /// The last `maxContextChars` Characters of the text.
    static func context(_ text: String) -> String {
        String(text.suffix(GhostTextPolicy.maxContextChars))
    }

    /// nil unless the snapshot passes `GhostTextPolicy.allows`.
    static func build(_ s: GhostTextSnapshot) -> String? {
        guard GhostTextPolicy.allows(s), let text = s.textBeforeCaret else { return nil }
        return "App: \(s.appName)\nWindow: \(s.windowTitle)\nText so far (continue from the end):\n\(context(text))"
    }

    /// Turns the raw model reply into a single short suggestion, or nil when nothing usable is left.
    static func clean(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let firstLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        var body = firstLine.trimmingCharacters(in: .whitespaces)
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("\u{201C}", "\u{201D}")]
        if body.count >= 2, let first = body.first, let last = body.last,
           pairs.contains(where: { $0.0 == first && $0.1 == last }) {
            let inner = String(body.dropFirst().dropLast())
            // Keep the quotes when the reply holds several quoted phrases ("Yes" or "no").
            if !inner.contains(first) && !inner.contains(last) { body = inner }
        }
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(GhostTextPolicy.maxSuggestionWords)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// Joins an accepted suggestion to the text before the caret. The suggestion loses its leading whitespace.
    /// One space is added only when the context ends in a letter, digit or .,;:!? and the suggestion starts
    /// with a letter or digit. An empty context or one ending in whitespace gets no space.
    static func join(context: String, suggestion: String) -> String {
        let s = String(suggestion.drop(while: { $0.isWhitespace }))
        guard let last = context.last, !last.isWhitespace, let first = s.first else { return s }
        let endsWord = last.isLetter || last.isNumber || ".,;:!?".contains(last)
        return endsWord && (first.isLetter || first.isNumber) ? " " + s : s
    }
}
