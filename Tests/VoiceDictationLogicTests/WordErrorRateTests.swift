import XCTest
@testable import VoiceDictationLogic

/// U6 / v2-8: the accuracy table's metric, word error rate on normalized words.
final class WordErrorRateTests: XCTestCase {
    func testIdenticalTextIsZero() {
        XCTAssertEqual(WordErrorRate.wer(reference: "send it to june", hypothesis: "send it to june"), 0)
    }

    func testOneSubstitutionInFiveWordsIsTwentyPercent() {
        XCTAssertEqual(
            WordErrorRate.wer(reference: "one two three four five", hypothesis: "one two tree four five"),
            0.2, accuracy: 1e-9)
    }

    func testInsertionCountsAgainstTheReference() {
        XCTAssertEqual(WordErrorRate.wer(reference: "a b", hypothesis: "a b c"), 0.5, accuracy: 1e-9)
    }

    func testEmptyHypothesisIsOne() {
        XCTAssertEqual(WordErrorRate.wer(reference: "send it", hypothesis: ""), 1.0, accuracy: 1e-9)
    }

    func testPunctuationAndCaseAreIgnored() {
        XCTAssertEqual(WordErrorRate.wer(reference: "Send it to June.", hypothesis: "send it to june"), 0)
    }
}
