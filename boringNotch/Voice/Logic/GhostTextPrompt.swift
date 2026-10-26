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
            body = String(body.dropFirst().dropLast())
        }
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(GhostTextPolicy.maxSuggestionWords)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// Joins an accepted suggestion to the text before the caret. Adds one space when the context
    /// ends in a word and the suggestion starts with a letter or digit, unless both sides are CJK
    /// (which carry no spaces between words).
    static func join(context: String, suggestion: String) -> String {
        guard let last = context.last, let first = suggestion.first,
              !last.isWhitespace, first.isLetter || first.isNumber else { return suggestion }
        if isCJK(last) && isCJK(first) { return suggestion }
        return " " + suggestion
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v)
            || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
}
