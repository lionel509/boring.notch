import Foundation

enum GhostTextPrompt {
    static let instructions = "Continue the user's text from exactly where it ends. Reply with only the next 1 to \(GhostTextPolicy.maxSuggestionWords) words, then stop. Never finish the sentence, never add end punctuation, never start a new line. Same language and tone. No quotes, no explanation, never repeat the given text."

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
        // A quoted phrase may be followed by plain punctuation: "world". becomes world.
        if let first = body.first, let pair = pairs.first(where: { $0.0 == first }),
           let end = body.lastIndex(of: pair.1), end > body.startIndex {
            let tail = body[body.index(after: end)...]
            if tail.allSatisfy({ ".,;:!?".contains($0) }) {
                let inner = String(body[body.index(after: body.startIndex)..<end])
                // Keep the quotes when the reply holds several quoted phrases ("Yes" or "no").
                if !inner.contains(first) && !inner.contains(pair.1) { body = inner + tail }
            }
        }
        // Round 11 (#47): continue the words, never a clause or a sentence. Leading punctuation goes first, then the
        // reply is cut at the first stop that ends a word, and stops left at the end are trimmed.
        // Quote marks stay: a reply of several quoted phrases keeps them (see the quote rule above).
        body = String(body.drop(while: { !$0.isLetter && !$0.isNumber && !"\"'`\u{201C}\u{201D}".contains($0) }))
        var i = body.startIndex
        while i < body.endIndex {
            let next = body.index(after: i)
            if GhostTextPolicy.suggestionStops.contains(body[i]), next == body.endIndex || body[next].isWhitespace {
                body = String(body[..<i]); break
            }
            i = next
        }
        while let last = body.last, GhostTextPolicy.suggestionStops.contains(last) { body.removeLast() }
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(GhostTextPolicy.maxSuggestionWords)
        guard !words.isEmpty else { return nil }
        let suggestion = words.joined(separator: " ")
        // Fences, quote marks, ellipses and rules have no words: nothing to show or insert.
        guard suggestion.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return suggestion
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
