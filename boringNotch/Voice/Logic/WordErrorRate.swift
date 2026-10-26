import Foundation

/// Word error rate for the accuracy table (v2-8): Levenshtein distance over normalized words,
/// divided by the reference word count. Pure text, no audio or network.
enum WordErrorRate {
    /// Lowercased, punctuation stripped, split on whitespace. Empty tokens are dropped.
    static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                ? Character(scalar) : " "
        }
        return String(cleaned).split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
    }

    /// 0 for identical text, 1.0 for an empty hypothesis against a non-empty reference.
    /// Insertions count against the reference too, so the result can exceed 1.0.
    /// An empty reference scores 0 when the hypothesis is also empty, otherwise 1.0.
    static func wer(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        if ref.isEmpty { return hyp.isEmpty ? 0 : 1.0 }
        var previous = Array(0...hyp.count)
        var current = [Int](repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            current[0] = i
            for j in stride(from: 1, through: hyp.count, by: 1) {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }
}
