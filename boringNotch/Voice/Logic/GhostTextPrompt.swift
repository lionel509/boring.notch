import Foundation

enum GhostTextPrompt {
    static let instructions = "Continue the text from exactly where it ends with the next 1 to \(GhostTextPolicy.maxSuggestionWords) words, in the same language. Reply with only those words. Never repeat the text."

    /// The last `maxContextChars` Characters of the text.
    static func context(_ text: String) -> String {
        String(text.suffix(GhostTextPolicy.maxContextChars))
    }

    /// nil unless the snapshot passes `GhostTextPolicy.allows`.
    static func build(_ s: GhostTextSnapshot) -> String? {
        guard GhostTextPolicy.allows(s), let text = s.textBeforeCaret else { return nil }
        return "App: \(s.appName)\nWindow: \(String(s.windowTitle.prefix(80)))\nText so far (continue from the end):\n\(context(text))"
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
        body = String(body.drop(while: { !$0.isLetter && !$0.isNumber && !"\"'`\u{201C}\u{201D}$-#@([".contains($0) }))
        var i = body.startIndex
        while i < body.endIndex {
            let next = body.index(after: i)
            let c = body[i]
            if GhostTextPolicy.cjkStops.contains(c) || (GhostTextPolicy.suggestionStops.contains(c) && (next == body.endIndex || body[next].isWhitespace)) {
                body = String(body[..<i]); break
            }
            i = next
        }
        while let last = body.last, GhostTextPolicy.suggestionStops.contains(last) || GhostTextPolicy.cjkStops.contains(last) { body.removeLast() }
        let words = body.split(whereSeparator: { $0.isWhitespace }).prefix(GhostTextPolicy.maxSuggestionWords)
        guard !words.isEmpty else { return nil }
        let suggestion = words.joined(separator: " ")
        // Fences, quote marks, ellipses and rules have no words: nothing to show or insert.
        guard suggestion.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return suggestion
    }

    /// Round 12 (#47, break 5): common abbreviations that end in a dot and are followed by a space.
    static let joinAbbreviations: Set<String> = ["etc.", "vs.", "approx.", "incl.", "cf.", "al.", "ca.", "no.", "e.g.", "i.e."]

    /// Round 12 (#47, break 5): a dot inside a token takes no space ("version 3." + "14", "notes." + "md").
    /// Digit.digit always; letter.word only for one lowercase/digit word of at most 4 characters after a
    /// token with no other dot that isn't a known abbreviation. "Done." + "Thanks" keeps its space.
    static func continuesToken(context: String, suggestion s: String) -> Bool {
        guard context.last == ".", let first = s.first else { return false }
        let token = String(context.split(whereSeparator: { $0.isWhitespace }).last ?? "")
        let stem = token.dropLast()
        guard let beforeDot = stem.last, !stem.contains(".") else { return false }
        if beforeDot.isNumber { return first.isNumber }
        guard beforeDot.isLetter, !joinAbbreviations.contains(token.lowercased()) else { return false }
        return s.count <= 4 && s.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber }
    }

    /// Round 12 (#47, break 4): drops a first suggestion word that repeats the last word before the caret
    /// (case-insensitive, trailing stops ignored). nil when nothing is left. Other suggestions come back unchanged.
    static func dedupe(context: String, suggestion: String) -> String? {
        func bare(_ w: Substring) -> String {
            var w = w
            while let l = w.last, GhostTextPolicy.suggestionStops.contains(l) || GhostTextPolicy.cjkStops.contains(l) { w.removeLast() }
            return w.lowercased()
        }
        guard let lastWord = context.split(whereSeparator: { $0.isWhitespace }).last else { return suggestion }
        var words = suggestion.split(whereSeparator: { $0.isWhitespace })
        guard let firstWord = words.first, !bare(firstWord).isEmpty, bare(firstWord) == bare(lastWord) else { return suggestion }
        words.removeFirst()
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Joins an accepted suggestion to the text before the caret. The suggestion loses its leading whitespace.
    /// One space is added only when the context ends in a letter, digit or .,;:!? and the suggestion starts
    /// with a letter or digit. An empty context or one ending in whitespace gets no space.
    static func join(context: String, suggestion: String) -> String {
        let s = String(suggestion.drop(while: { $0.isWhitespace }))
        guard let last = context.last, !last.isWhitespace, let first = s.first else { return s }
        if continuesToken(context: context, suggestion: s) { return s }
        let endsWord = last.isLetter || last.isNumber || ".,;:!?".contains(last)
        return endsWord && (first.isLetter || first.isNumber) ? " " + s : s
    }
}
