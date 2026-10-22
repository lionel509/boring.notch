import XCTest
@testable import VoiceDictationLogic

/// U4 / v4-2: the streamed cleanup is swapped in sentence by sentence, so a sentence counts only once it ends.
final class SentenceSplitterTests: XCTestCase {
    func testOpenSentenceIsNotComplete() {
        let result = SentenceSplitter.completeSentences(in: "Hi there. How are you", streamEnded: false)
        XCTAssertEqual(result.sentences, ["Hi there."])
        XCTAssertEqual(result.rest, "How are you")
    }

    func testStreamEndMakesTheRestASentence() {
        let result = SentenceSplitter.completeSentences(in: "Hi there. How are you", streamEnded: true)
        XCTAssertEqual(result.sentences, ["Hi there.", "How are you"])
        XCTAssertEqual(result.rest, "")
    }

    func testEllipsisAndExclamationAndQuestionEndSentences() {
        let result = SentenceSplitter.completeSentences(in: "Wait… what?! Ok", streamEnded: false)
        XCTAssertEqual(result.sentences, ["Wait…", "what?!"])
        XCTAssertEqual(result.rest, "Ok")
    }

    func testDecimalPointDoesNotEndASentence() {
        let result = SentenceSplitter.completeSentences(in: "3.14 is pi.", streamEnded: false)
        XCTAssertEqual(result.sentences, ["3.14 is pi."])
        XCTAssertEqual(result.rest, "")
    }

    /// A digit before a final "." may still grow into a decimal ("3." then "3.5"), so it waits for the stream end.
    func testOpenDigitPointAtTheEndWaitsForMoreText() {
        XCTAssertEqual(SentenceSplitter.completeSentences(in: "Hi there.", streamEnded: false).sentences, ["Hi there."])
        XCTAssertEqual(SentenceSplitter.completeSentences(in: "The price is 3.", streamEnded: false).sentences, [])
        XCTAssertEqual(SentenceSplitter.completeSentences(in: "The price is 3.", streamEnded: true).sentences,
                       ["The price is 3."])
    }
}
