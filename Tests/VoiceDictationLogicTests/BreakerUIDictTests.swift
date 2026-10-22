import XCTest
@testable import VoiceDictationLogic

/// Breaker round 1 (UI strip + personal dictionary). Each test is meant to fail on PR #15 head be446fb.
final class BreakerUIDictTests: XCTestCase {

    // MARK: - DictationStrip

    /// Invariant I5: messages are <= 28 characters. A runtime failure with no "." or ":" inside the
    /// first 28 characters (VoiceDictationManager passes `error.localizedDescription` straight to `fail`)
    /// reaches the 150 pt cell whole, because `headline` never caps it.
    func testBreakerHeadlineIsCappedForLocalizedErrorText() {
        let message = "The operation couldn\u{2019}t be completed (Speech error 1)"
        let headline = DictationStrip.headline(message)
        XCTAssertLessThanOrEqual(headline.count, DictationStrip.headlineMax, "headline was \(headline.count) chars: \(headline)")
    }

    // MARK: - PersonalDictionary

    /// "whitespace-only lines" from web or Notion paste often carry a zero-width space or BOM, which
    /// `.whitespacesAndNewlines` does not strip, so the line survives as a dictionary word.
    func testBreakerByteOrderMarkLineIsNotAWord() throws {
        try XCTSkip("deferred to FOLLOWUPS per review r1: BOM trimming in PersonalDictionary")
        let words = PersonalDictionary.parseManual("Jun\n\u{FEFF}\nKubernetes")
        XCTAssertEqual(words, ["Jun", "Kubernetes"])
    }

    /// Invariant: the dictionary holds at most 200 words, and a word he corrected once must be able to
    /// reach the promotion count. Once 200 single-correction words fill the table, a new correction
    /// that sorts first alphabetically is evicted the moment it is learned, so it never reaches count 2.
    func testBreakerNewLearnedWordSurvivesAFullTable() {
        var learned: [String: Int] = [:]
        for i in 0..<200 { learned["word\(String(format: "%03d", i))"] = 1 }
        PersonalDictionary.learn(["Jun"], into: &learned)
        PersonalDictionary.learn(["Jun"], into: &learned)
        let words = PersonalDictionary.words(manual: "", learned: learned)
        XCTAssertTrue(words.contains("Jun"), "Jun was learned twice but is not in the dictionary: \(words.prefix(3))")
    }

    // MARK: - CorrectionLearner

    /// "the user continuing to type": the field now reads "decks", so the learner treats the typed
    /// "s" as a correction and learns "decks". Expected: nothing learned, the user only extended a word.
    func testBreakerTypingAnSuffixIsNotACorrection() throws {
        try XCTSkip("deferred to FOLLOWUPS per review r1: learner inflection rule")
        let found = CorrectionLearner.candidates(
            pasted: "we shipped the deck",
            current: "we shipped the decks"
        )
        XCTAssertEqual(found, [])
    }

    /// "corrections that would teach a common word": replacing "jon" with "the" is learned as "the",
    /// because the learner has no stopword check. Two such edits promote "the" into every future prompt.
    func testBreakerCommonWordIsNotLearned() throws {
        try XCTSkip("deferred to FOLLOWUPS per review r1: learner stopword guard")
        let found = CorrectionLearner.candidates(
            pasted: "send it to jon tomorrow",
            current: "send it to the tomorrow"
        )
        XCTAssertEqual(found, [])
    }

    /// Ship-blocker check on cost: the learner runs on the main actor after every paste (8 s later),
    /// over the whole focused field. Window search is O(field x 7 x pasted^2) with a fresh LCS table each time.
    /// Budget 2 s for a 150-word dictation in a 4000-word field.
    func testBreakerLearnerFinishesOnALongField() {
        var rng = LCG(seed: 7)
        let pool = (0..<500).map { _ in rng.word(minLength: 3, maxLength: 8) }
        let pasted = (0..<150).map { _ in pool[rng.int(0, pool.count - 1)] }.joined(separator: " ")
        let current = (0..<4000).map { _ in pool[rng.int(0, pool.count - 1)] }.joined(separator: " ")
        let start = Date()
        _ = CorrectionLearner.candidates(pasted: pasted, current: current)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, String(format: "candidates took %.2f s", elapsed))
    }
}
