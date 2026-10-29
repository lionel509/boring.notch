import Foundation

/// The dictionary behind mid-word ghost text (#58). The app passes NSSpellChecker (GhostWordSpeller); tests pass a fake.
/// Main actor because NSSpellChecker is AppKit.
@MainActor
protocol GhostWordCompleting {
    /// Whole words that start with `partial`, most likely first; empty when there are none.
    func completions(forPartial partial: String) -> [String]
}

/// The keyboard input source as the system reports it (#62 round 2). The app reads TIS; tests pass a fake.
protocol GhostInputSourceReading {
    /// kTISPropertyInputSourceType of the current input source, or nil when it cannot be read.
    func currentInputSourceType() -> String?
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

    /// The word path runs only on a plain keyboard layout (#62 round 2). An input method (Pinyin, Japanese, Korean) can hold
    /// marked text that reads as letters, so the path is refused while one is active, and when the type cannot be read.
    static func wordPathAllowed(_ source: GhostInputSourceReading) -> Bool {
        source.currentInputSourceType() == "TISTypeKeyboardLayout"
    }

    /// The rest of the word to draw after the caret, or nil. nil when any candidate in the dictionary's list is the typed
    /// word itself (#62 round 2: a finished word is never extended). Otherwise the first longer candidate (at most 24
    /// characters) that starts with the typed letters and adds only letters or apostrophes.
    @MainActor
    static func completion(before text: String, dictionary: GhostWordCompleting) -> String? {
        guard let partial = partialWord(text) else { return nil }
        let key = partial.lowercased()
        let candidates = dictionary.completions(forPartial: partial)
        if candidates.contains(where: { $0.lowercased() == key }) { return nil }
        for candidate in candidates {
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
