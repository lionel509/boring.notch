import XCTest
@testable import VoiceDictationLogic

/// Scope 5 (phase 1) and invariant I3: only short alphabetic words that replaced a
/// dictated word are candidates; nothing else is kept.
final class CorrectionLearnerTests: XCTestCase {
    func testFindsTheWordHeCorrected() {
        let found = CorrectionLearner.candidates(
            pasted: "send it to jon tomorrow",
            current: "Hi,\nsend it to Jun tomorrow. Thanks"
        )
        XCTAssertEqual(found, ["Jun"])
    }

    func testNoOccurrenceOfThePastedTextGivesNothing() {
        let found = CorrectionLearner.candidates(
            pasted: "send it to jon tomorrow",
            current: "completely unrelated sentence about cats"
        )
        XCTAssertEqual(found, [])
    }

    /// 300 deterministic rounds of random pairs, including junk that must never be learned.
    func testFuzzCandidatesAreShortAlphabeticAndFromTheField() {
        var rng = LCG(seed: 29)
        let pool = (0..<40).map { _ in rng.word(minLength: 2, maxLength: 9) }
        let junk = ["a@b.example", "12345", "😀", String(repeating: "x", count: 40), "it's", "well-known"]
        func token() -> String {
            rng.int(0, 4) == 0 ? junk[rng.int(0, junk.count - 1)] : pool[rng.int(0, pool.count - 1)]
        }
        for _ in 0..<300 {
            let pasted = (0..<rng.int(3, 10)).map { _ in token() }.joined(separator: " ")
            let words = pasted.split(separator: " ").map(String.init)
            let current = (0..<rng.int(3, 10)).map { _ in
                rng.int(0, 2) == 0 ? token() : words[rng.int(0, words.count - 1)]
            }.joined(separator: " ")
            let found = CorrectionLearner.candidates(pasted: pasted, current: current)
            XCTAssertLessThanOrEqual(found.count, 5)
            for word in found {
                XCTAssertTrue((3...30).contains(word.count), word)
                XCTAssertTrue(word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }, word)
                XCTAssertTrue(current.lowercased().contains(word.lowercased()), word)
                XCTAssertFalse(pasted.lowercased().contains(word.lowercased()), word)
            }
        }
    }
}

extension LCG: RandomNumberGenerator {}
