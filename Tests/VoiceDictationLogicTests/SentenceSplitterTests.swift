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
        XCTAssertEqual(result.sentences, [])
        XCTAssertEqual(result.rest, "3.14 is pi.")
    }

    func testTerminatorAtTheEndCompletesOnlyWhenTheStreamEnds() {
        XCTAssertEqual(SentenceSplitter.completeSentences(in: "Hi there.", streamEnded: false).sentences, [])
        XCTAssertEqual(SentenceSplitter.completeSentences(in: "Hi there.", streamEnded: true).sentences, ["Hi there."])
    }
}
