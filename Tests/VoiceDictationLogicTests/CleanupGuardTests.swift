import XCTest
@testable import VoiceDictationLogic

/// Invariant I2: what gets pasted is the raw transcript or an LLM output that passed
/// `CleanupGuard.accept`. An answer, a refusal or a rewrite must be rejected.
final class CleanupGuardTests: XCTestCase {
    func testIdentityIsAccepted() {
        let raw = "um so hey can you send the file"
        XCTAssertTrue(CleanupGuard.accept(raw: raw, cleaned: raw))
    }

    func testEmptyOutputIsRejected() {
        XCTAssertFalse(CleanupGuard.accept(raw: "hello there friend", cleaned: ""))
        XCTAssertFalse(CleanupGuard.accept(raw: "hello there friend", cleaned: "   \n "))
    }

    /// The model answered the question instead of cleaning the words.
    func testAnswerToADictatedQuestionIsRejected() {
        XCTAssertFalse(CleanupGuard.accept(raw: "what time is it", cleaned: "I don't have access to a clock"))
    }

    func testNormalizeStripsWrappingQuotes() {
        XCTAssertEqual(CleanupGuard.normalize("\"Hey there.\""), "Hey there.")
    }

    func testNormalizeDropsALeadingLabel() {
        XCTAssertEqual(CleanupGuard.normalize("Cleaned text: Hey."), "Hey.")
        XCTAssertEqual(CleanupGuard.normalize("Output: Hey."), "Hey.")
    }

    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(CleanupGuard.normalize("  Hey \n\n there.  "), "Hey there.")
    }

    /// v2-3 / v4-2: a streamed sentence is checked against the raw words it aligned to.
    func testSentenceWithMostWordsInTheRawWindowIsAccepted() {
        XCTAssertTrue(CleanupGuard.acceptSentence(sentence: "Send it to June.", rawWindow: "um send it to jon no wait june"))
    }

    func testSentenceThatAnswersTheRawIsRejected() {
        XCTAssertFalse(CleanupGuard.acceptSentence(sentence: "I cannot help with that request.", rawWindow: "what time is it"))
    }

    func testShortSentenceIsNotJudgedByOverlap() {
        XCTAssertTrue(CleanupGuard.acceptSentence(sentence: "Okay.", rawWindow: "what time is it"))
    }

    /// Deterministic fuzz over random word lists (200 rounds).
    func testFuzzRawIsAcceptedAndAddedWordsAreRejected() {
        var rng = LCG(seed: 13)
        let pool = (0..<60).map { _ in rng.word(minLength: 3, maxLength: 8) }
        for _ in 0..<200 {
            let count = rng.int(3, 12)
            let raw = (0..<count).map { _ in pool[rng.int(0, pool.count - 1)] }.joined(separator: " ")
            XCTAssertTrue(CleanupGuard.accept(raw: raw, cleaned: raw), raw)

            let padded = raw + " " + (0..<3).map { _ in pool[rng.int(0, pool.count - 1)] }.joined(separator: " ")
            XCTAssertFalse(CleanupGuard.accept(raw: raw, cleaned: padded), padded)

            let unrelated = (0..<count).map { _ in "q" + rng.word(minLength: 3, maxLength: 8) }.joined(separator: " ")
            XCTAssertFalse(CleanupGuard.accept(raw: raw, cleaned: unrelated), unrelated)
        }
    }
}

/// Small deterministic generator so the fuzz results are reproducible.
struct LCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }

    mutating func int(_ low: Int, _ high: Int) -> Int {
        low + Int(next() % UInt64(high - low + 1))
    }

    mutating func word(minLength: Int, maxLength: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let length = int(minLength, maxLength)
        return String((0..<length).map { _ in letters[int(0, letters.count - 1)] })
    }
}
