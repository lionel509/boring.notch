import XCTest
@testable import VoiceDictationLogic

/// Breaker round 2 against PR #15 at head 3c297c4. Each test is one realistic input that a round-1 fix
/// still gets wrong. Red on 3c297c4 is the point of these tests.
final class BreakerR2Tests: XCTestCase {

    /// R2-1. Fix 3(b) aligns the open partial by matching its words in order. A contraction expansion
    /// ("gonna" cleaned to "going to") leaves "going" unmatched, but "to" still matches a later "to" in
    /// the raw text, so the tail starts after it and "gonna send it" is dropped from the target. On an
    /// abort or the 8 s deadline that target stays in the field.
    func testR2ContractionExpansionDropsSendItWhenToRecurs() {
        var state = AlignState()
        let target = RewritePlanner.target(
            cleaned: "I'm going to", streamEnded: false,
            raw: "I'm gonna send it to June on Thursday", state: &state)
        let shown = Set(target.split(separator: " ").map(String.init))
        for word in ["send", "it", "June", "Thursday"] {
            XCTAssertTrue(shown.contains(word), "word '\(word)' of the take is missing from the target: \(target)")
        }
    }

    /// R2-2. Fix 3(a) only waits for a "." after a digit. A "." after "Dr" closes "Tell Dr." at once, so the
    /// abbreviation anchors the raw cursor by a word-count fallback that skips "doctor lee". The next partial
    /// word "Lee" is then not found after the cursor, the stored target is reused, and the name vanishes.
    func testR2AbbreviationSplitLosesTheNameOnTheNextPartialWord() {
        var state = AlignState()
        let raw = "tell doctor lee about the lab results"
        _ = RewritePlanner.target(cleaned: "Tell Dr.", streamEnded: false, raw: raw, state: &state)
        let target = RewritePlanner.target(cleaned: "Tell Dr. Lee", streamEnded: false, raw: raw, state: &state)
        XCTAssertEqual(target, "Tell Dr. Lee about the lab results")
    }

    /// R2-3. Fix 2 rejects any cleanup under 40 % of the raw word count. A filler-heavy but legitimate
    /// cleanup (10 fillers in 16 words, cleaned to 6 words) is discarded, so the user gets the raw text
    /// with every "um" and "uh" in it. This is a realistic take, not a cut-off stream.
    func testR2FillerHeavyLegitimateCleanupIsRejectedByTheLowerBound() {
        let raw = "um uh so um uh I think um uh we should um uh go um uh"
        XCTAssertTrue(CleanupGuard.accept(raw: raw, cleaned: "So I think we should go."),
                      "a faithful cleanup of a filler-heavy take must be accepted")
    }

    /// R2-4. Fix 6 returns [] for any pair product over 200 000. A 65-word take pasted into a 4 000-word
    /// document (65 * 4 000 = 260 000 pairs) is therefore never learned, although the user corrected a
    /// name in it. Learning is silently switched off for any real take in a long document.
    func testR2LongFieldDisablesLearningForARealTake() {
        let filler = Array(repeating: "lorem ipsum dolor sit amet consectetur adipiscing elit sed do", count: 400)
            .joined(separator: " ")
        let take = Array(repeating: "meeting notes review", count: 20).joined(separator: " ")
            + " send it to jon tomorrow"
        let pasted = take
        let current = filler + " " + take.replacingOccurrences(of: "jon", with: "Jun") + " " + filler
        XCTAssertEqual(CorrectionLearner.candidates(pasted: pasted, current: current), ["Jun"])
    }
}
