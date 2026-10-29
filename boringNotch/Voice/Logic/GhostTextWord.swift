import Foundation

/// The dictionary behind mid-word ghost text (#58). The app passes NSSpellChecker (GhostWordSpeller); tests pass a fake.
/// Main actor because NSSpellChecker is AppKit.
@MainActor
protocol GhostWordCompleting {
    /// Whole words that start with `partial`, most likely first; empty when there are none.
    func completions(forPartial partial: String) -> [String]
}

/// Finishes the word at the caret from the system dictionary (#58). No model, no prompt.
enum GhostTextWord {
    static let minPrefix = 3
    static let maxWordChars = 24
    /// Besides whitespace and the start of the text, the only characters a partial word may follow.
    static let openers: Set<Character> = ["\"", "(", "[", "\u{201C}"]

    /// True when the only check that refused the snapshot is the word boundary: every other gate passed and the caret is mid-word.
    static func routes(_ s: GhostTextSnapshot) -> Bool {
        GhostTextPolicy.failedCheck(s) == .notWordBoundary
    }

    /// The 3 to 24 letters being typed at the end of `text`, or nil. CJK (U+2E80 and up) is never completed.
    static func partialWord(_ text: String) -> String? {
        let run = text.reversed().prefix(while: { $0.isLetter })
        guard run.count >= minPrefix, run.count <= maxWordChars,
              run.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value < 0x2E80 } }) else { return nil }
        if let previous = text.dropLast(run.count).last, !previous.isWhitespace, !openers.contains(previous) { return nil }
        return String(run.reversed())
    }

    /// The rest of the word to draw after the caret, or nil. The dictionary's order decides: nil when the typed word itself
    /// comes before any usable candidate; otherwise the first longer candidate (at most 24 characters) that starts with the
    /// typed letters and adds only letters or apostrophes.
    @MainActor
    static func completion(before text: String, dictionary: GhostWordCompleting) -> String? {
        guard let partial = partialWord(text) else { return nil }
        let key = partial.lowercased()
        for candidate in dictionary.completions(forPartial: partial) {
            if candidate.lowercased() == key { return nil }
            guard candidate.count > partial.count, candidate.count <= maxWordChars,
                  String(candidate.prefix(partial.count)).lowercased() == key else { continue }
            let rest = String(candidate.dropFirst(partial.count))
            guard rest.contains(where: { $0.isLetter }),
                  rest.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else { continue }
            return matchCase(rest, typed: partial, candidate: candidate)
        }
        return nil
    }

    /// All-caps typing (2+ letters) upper-cases the rest; an all-caps candidate after other typing lower-cases it;
    /// otherwise the dictionary's own case.
    static func matchCase(_ rest: String, typed: String, candidate: String) -> String {
        if typed.count >= 2, typed == typed.uppercased(), typed != typed.lowercased() { return rest.uppercased() }
        if candidate == candidate.uppercased(), candidate != candidate.lowercased() { return rest.lowercased() }
        return rest
    }
}
