//
//  SentenceSplitter.swift
//  boringNotch
//

import Foundation

/// Splits streamed cleanup text into complete sentences, so each one is swapped in only once it ends.
enum SentenceSplitter {
    private static let terminators: Set<Character> = [".", "!", "?", "…"]

    /// Words that end in a "." without ending a sentence ("Dr. Lee", "e.g. this").
    private static let abbreviations: Set<String> = ["dr", "mr", "mrs", "ms", "prof", "st", "jr", "sr", "vs", "e.g", "i.e"]

    /// A sentence ends at a terminator followed by whitespace. A "." that is the last character of an open stream
    /// and follows a digit does not end a sentence yet, because more digits may turn "3." into "3.5". Other
    /// terminators at the end count at once. A "." that closes an abbreviation ("Dr.") does not end a sentence,
    /// except as the last character with `streamEnded`. With `streamEnded`, a non-empty rest counts as the last
    /// sentence.
    static func completeSentences(in text: String, streamEnded: Bool) -> (sentences: [String], rest: String) {
        let chars = Array(text)
        var sentences: [String] = []
        var start = 0
        for i in chars.indices where terminators.contains(chars[i]) {
            let atEnd = i + 1 == chars.count
            let mayBeDecimal = chars[i] == "." && i > 0 && chars[i - 1].isNumber
            var wordStart = i
            while wordStart > 0, !chars[wordStart - 1].isWhitespace { wordStart -= 1 }
            let word = String(chars[wordStart..<i]).lowercased()
            let abbreviated = chars[i] == "." && abbreviations.contains(word)
            let ends: Bool
            if atEnd {
                ends = streamEnded || (!mayBeDecimal && !abbreviated)
            } else {
                ends = chars[i + 1].isWhitespace && !abbreviated
            }
            guard ends else { continue }
            let sentence = String(chars[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            start = i + 1
        }
        let rest = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if streamEnded, !rest.isEmpty {
            return (sentences + [rest], "")
        }
        return (sentences, rest)
    }
}
