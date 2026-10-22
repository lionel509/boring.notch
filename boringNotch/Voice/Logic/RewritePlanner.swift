//
//  RewritePlanner.swift
//  boringNotch
//

import Foundation

/// One whole-span replacement inside the inserted text: the first `prefixUTF16` units stay, `oldMiddle`
/// becomes `newMiddle`, and the last `suffixUTF16` units stay.
struct RewriteStep: Equatable {
    let prefixUTF16: Int
    let oldMiddle: String
    let newMiddle: String
    let suffixUTF16: Int
    let suffixGraphemes: Int

    var oldMiddleGraphemes: Int { oldMiddle.count }

    func apply(to committed: String) -> String {
        let units = Array(committed.utf16)
        let head = String(decoding: units[0..<prefixUTF16], as: UTF16.self)
        let tail = String(decoding: units[(units.count - suffixUTF16)...], as: UTF16.self)
        return head + newMiddle + tail
    }
}

/// Where the planner is in the raw text. Lives for one take.
struct AlignState: Equatable {
    /// Index of the first raw word not yet covered by a completed cleaned sentence.
    var rawCursor = 0
    /// How many complete cleaned sentences have already moved the cursor.
    var anchoredSentences = 0
}

/// Pure text planning for the in-place rewrite: which target the field should show, and the smallest
/// whole-span step that gets there from what is committed now.
enum RewritePlanner {
    /// Words that never identify a sentence. Matching uses the last two content words only.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "on", "in", "at", "for", "with", "by",
        "is", "are", "was", "were", "be", "it", "its", "i", "me", "my", "we", "you", "he", "she", "they",
        "that", "this", "um", "uh",
    ]

    /// Collapses every whitespace run, newlines included, to one space. A typed Return would send a message.
    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The text the field should show now: the cleaned sentences so far, then the raw words not yet covered.
    /// With `streamEnded` there is no raw tail. Updates `state` when new sentences complete.
    static func target(cleaned: String, streamEnded: Bool, raw: String, state: inout AlignState) -> String {
        let text = normalize(cleaned)
        let (sentences, rest) = SentenceSplitter.completeSentences(in: text, streamEnded: streamEnded)
        let rawWords = words(raw)
        if sentences.count > state.anchoredSentences {
            for sentence in sentences[state.anchoredSentences...] {
                state.rawCursor = anchor(after: sentence, raw: rawWords, cursor: state.rawCursor)
            }
            state.anchoredSentences = sentences.count
        }
        if streamEnded { return text }
        // The partial sentence is estimated one raw word per cleaned word; the next sentence end corrects it.
        let tailStart = min(state.rawCursor + words(rest).count, rawWords.count)
        let tail = rawWords[tailStart...].joined(separator: " ")
        if tail.isEmpty { return text }
        return text.isEmpty ? tail : text + " " + tail
    }

    /// The smallest whole-span change from `committed` to `target`, or nil when they are equal. The cut
    /// falls on grapheme boundaries, so no surrogate pair or combining mark is ever split.
    static func step(from committed: String, to target: String) -> RewriteStep? {
        guard committed != target else { return nil }
        let a = Array(committed)
        let b = Array(target)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        return RewriteStep(
            prefixUTF16: String(a[0..<prefix]).utf16.count,
            oldMiddle: String(a[prefix..<(a.count - suffix)]),
            newMiddle: String(b[prefix..<(b.count - suffix)]),
            suffixUTF16: String(a[(a.count - suffix)...]).utf16.count,
            suffixGraphemes: suffix)
    }

    /// The raw words the sentence being checked may have come from, for `CleanupGuard.acceptSentence`.
    static func rawWindow(raw: String, state: AlignState, sentenceWords: Int) -> String {
        let all = words(raw)
        let start = min(state.rawCursor, all.count)
        let end = min(all.count, start + 2 * sentenceWords + 8)
        return all[start..<end].joined(separator: " ")
    }

    // MARK: - Private

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// A word for matching: lowercased, letters and digits only.
    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Moves the raw cursor past the raw word that matches the sentence's last two content words, searching
    /// the window after the cursor. Ties go to the earliest match. No match: advance by the sentence's word
    /// count plus a 30 % filler allowance.
    private static func anchor(after sentence: String, raw: [String], cursor: Int) -> Int {
        let sentenceWords = words(sentence)
        let count = sentenceWords.count
        let fallback = min(raw.count, cursor + count + Int((0.3 * Double(count)).rounded()))
        let content = sentenceWords.map(key).filter { !$0.isEmpty && !stopwords.contains($0) }
        guard let last = content.last else { return fallback }
        let window = max(cursor, min(raw.count, cursor + 2 * count + 8))

        if content.count == 1 {
            for i in cursor..<window where key(raw[i]) == last { return i + 1 }
            return fallback
        }
        let second = content[content.count - 2]
        for i in cursor..<window where key(raw[i]) == second {
            for j in (i + 1)..<max(i + 1, window) where key(raw[j]) == last {
                return j + 1
            }
        }
        return fallback
    }
}
