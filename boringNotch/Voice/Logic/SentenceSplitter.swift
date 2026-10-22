//
//  SentenceSplitter.swift
//  boringNotch
//

import Foundation

/// Splits streamed cleanup text into complete sentences, so each one is swapped in only once it ends.
enum SentenceSplitter {
    private static let terminators: Set<Character> = [".", "!", "?", "…"]

    /// A sentence ends at a terminator followed by whitespace or by the end of the text. Abbreviations are
    /// not special-cased. With `streamEnded`, a non-empty rest counts as the last sentence.
    static func completeSentences(in text: String, streamEnded: Bool) -> (sentences: [String], rest: String) {
        let chars = Array(text)
        var sentences: [String] = []
        var start = 0
        for i in chars.indices where terminators.contains(chars[i]) {
            let atEnd = i + 1 == chars.count
            guard atEnd || chars[i + 1].isWhitespace else { continue }
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
