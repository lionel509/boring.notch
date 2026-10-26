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

    /// Joins an accepted suggestion to the text before the caret. Adds one space when the suggestion
    /// starts with a letter or digit, unless the context is empty or ends in whitespace, an opener or
    /// connector, an opening ASCII quote (preceded by whitespace or nothing), or both sides are from a
    /// script with no spaces between words (Han, Kana, CJK and fullwidth punctuation, Thai).
    static func join(context: String, suggestion: String) -> String {
        guard let last = context.last, let first = suggestion.first, !last.isWhitespace,
              first.isLetter || first.isNumber || openers.contains(first) || isEmoji(first) || symbolStarts.contains(first)
        else { return suggestion }
        if noSpaceAfter.contains(last) { return suggestion }
        // Glue after a currency sign only when a number follows (costs €100, but 50¢ each).
        if currency.contains(last) && first.isNumber { return suggestion }
        // A leading quote closes the user's open quote when the context holds an odd number of them.
        if first == "\"" && context.filter({ $0 == "\"" }).count % 2 == 1 { return suggestion }
        // Contraction: it + 's fine.
        if first == "'" && (last.isLetter || last.isNumber)
            && suggestion.dropFirst().first?.isLetter == true { return suggestion }
        let before = context.dropLast().last
        if last == "\"" || last == "'" {
            if before == nil || before!.isWhitespace || "([{=<".contains(before!) { return suggestion }
        }
        if "-\u{2013}\u{2014}<".contains(last) {
            // Spaced dash or operator gets a space; a glued one (long-term, <a) does not.
            return before?.isWhitespace == true ? " " + suggestion : suggestion
        }
        // Skip trailing closing punctuation (ellipsis, quotes, brackets) to find the real last character.
        guard let core = context.last(where: { !closers.contains($0) }) else {
            return isUnspaced(first) ? suggestion : " " + suggestion
        }
        if isUnspaced(core) && (isUnspaced(first) || "\u{201C}\u{2018}\u{AB}\u{201E}".contains(first)) { return suggestion }
        return " " + suggestion
    }

    private static let closers: Set<Character> = Set("\u{2026}\u{22EF}\u{2025}\"'\u{201D}\u{2019}\u{BB}\u{203A}")
    private static let openers: Set<Character> = Set("\u{BF}\u{A1}([{\u{201C}\u{2018}\u{AB}\u{201E}\u{2039}\"'")

    private static func isEmoji(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { $0.properties.isEmojiPresentation } ?? false
    }

    private static let noSpaceAfter: Set<Character> = Set("/\\@_([{#~`\u{201C}\u{2018}\u{AB}\u{BF}\u{A1}\u{201E}\u{2039}\u{FF08}\u{300C}\u{300E}\u{3010}")
    private static let currency: Set<Character> = Set("$\u{20AC}\u{A3}\u{A5}\u{20A9}\u{A2}\u{20B9}\u{20BD}\u{20BA}\u{20AA}\u{20B1}\u{20AB}")
    private static let symbolStarts: Set<Character> = Set("$@#&*+~<")

    private static func isUnspaced(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x0E00...0x0E7F).contains(v)          // Thai
            || (0x3000...0x30FF).contains(v)          // CJK punctuation, Hiragana, Katakana
            || (0x3400...0x9FFF).contains(v)          // CJK ideographs
            || (0xF900...0xFAFF).contains(v)          // CJK compatibility ideographs
            || (0xFF00...0xFFEF).contains(v)          // fullwidth forms
    }
}
