import Foundation

/// Finds the words he corrected after a paste: a word in the field that replaced a
/// dictated word. Only short alphabetic words are kept, so junk never reaches the dictionary.
enum CorrectionLearner {
    static let maxCandidates = 5
    /// Above this many token pairs the alignment is skipped: it would stall the caller on a long field.
    static let maxPairs = 200_000

    /// `pasted` is what we inserted. `current` is the field's text now. Returns at most
    /// `maxCandidates` words in the order they appear in `current`, without duplicates.
    static func candidates(pasted: String, current: String) -> [String] {
        let pastedTokens = tokens(pasted)
        let currentTokens = tokens(current)
        guard !pastedTokens.isEmpty, !currentTokens.isEmpty else { return [] }
        guard pastedTokens.count * currentTokens.count <= maxPairs else { return [] }

        // Each token is normalized once here; the alignment compares the keys only.
        let pastedKeys = pastedTokens.map(normalized)
        let currentKeys = currentTokens.map(normalized)
        let range = bestWindow(pasted: pastedKeys, current: currentKeys)
        var found: [String] = []
        var seen = Set<String>()
        let window = currentTokens[range]
        let windowKeys = currentKeys[range]
        for word in replacedWords(pasted: pastedKeys, windowKeys: windowKeys, window: window) {
            guard let clean = accepted(word, pasted: pasted, current: current) else { continue }
            guard seen.insert(clean.lowercased()).inserted else { continue }
            found.append(clean)
            if found.count == maxCandidates { break }
        }
        return found
    }

    // MARK: - Alignment

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The window of `current` (length within 3 of the pasted length) with the highest
    /// LCS against `pasted`. Ties go to the latest start, then the longer window. Both arrays hold keys.
    private static func bestWindow(pasted: [String], current: [String]) -> Range<Int> {
        let m = pasted.count
        var best = 0
        var bestStart = 0
        var bestLength = 0
        for start in current.indices {
            for length in max(1, m - 3)...(m + 3) where start + length <= current.count {
                let score = lcsLength(pasted, Array(current[start..<(start + length)]))
                let later = start > bestStart || (start == bestStart && length > bestLength)
                if score > best || (score == best && score > 0 && later) {
                    best = score
                    bestStart = start
                    bestLength = length
                }
            }
        }
        guard best > 0 else { return 0..<0 }
        return bestStart..<(bestStart + bestLength)
    }

    /// Words in `window` that sit where a pasted word was replaced: an unmatched run that has
    /// pasted words and window words on both sides, paired from the left.
    private static func replacedWords(pasted: [String], windowKeys: ArraySlice<String>, window: ArraySlice<String>) -> [String] {
        let w = Array(window)
        let steps = alignment(pasted, Array(windowKeys))
        var result: [String] = []
        var pendingPasted = 0
        var pendingWindow: [String] = []
        func flush() {
            let paired = min(pendingPasted, pendingWindow.count)
            result.append(contentsOf: pendingWindow.prefix(paired))
            pendingPasted = 0
            pendingWindow = []
        }
        for step in steps {
            switch step {
            case .match:
                flush()
            case .pastedOnly:
                pendingPasted += 1
            case .windowOnly(let index):
                pendingWindow.append(w[index])
            }
        }
        flush()
        return result
    }

    private enum Step {
        case match
        case pastedOnly
        case windowOnly(Int)
    }

    /// Backtracks the LCS table into an ordered list of steps. Inputs are normalized keys.
    private static func alignment(_ pasted: [String], _ window: [String]) -> [Step] {
        let table = lcsTable(pasted, window)
        var steps: [Step] = []
        var i = pasted.count
        var j = window.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, pasted[i - 1] == window[j - 1], table[i][j] == table[i - 1][j - 1] + 1 {
                steps.append(.match)
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || table[i][j - 1] >= table[i - 1][j] {
                steps.append(.windowOnly(j - 1))
                j -= 1
            } else {
                steps.append(.pastedOnly)
                i -= 1
            }
        }
        return steps.reversed()
    }

    private static func lcsLength(_ pasted: [String], _ window: [String]) -> Int {
        lcsTable(pasted, window)[pasted.count][window.count]
    }

    /// Inputs are normalized keys.
    private static func lcsTable(_ pasted: [String], _ window: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: window.count + 1), count: pasted.count + 1)
        for i in pasted.indices {
            for j in window.indices {
                table[i + 1][j + 1] = pasted[i] == window[j]
                    ? table[i][j] + 1
                    : max(table[i][j + 1], table[i + 1][j])
            }
        }
        return table
    }

    /// Tokens match ignoring case and surrounding punctuation ("tomorrow." is "tomorrow").
    private static func normalized(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    // MARK: - Filtering

    /// Strips surrounding punctuation, then keeps the word only if it is 3–30 characters of
    /// letters, apostrophes or hyphens and does not occur in the pasted text.
    private static func accepted(_ word: String, pasted: String, current: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard (3...30).contains(trimmed.count) else { return nil }
        guard trimmed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return nil }
        guard current.lowercased().contains(trimmed.lowercased()) else { return nil }
        guard !pasted.lowercased().contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }
}
