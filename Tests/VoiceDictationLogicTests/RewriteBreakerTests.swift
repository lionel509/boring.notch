import XCTest
@testable import VoiceDictationLogic

/// Breaker round 1 against PR #15 (rewrite engine). Each test is one reproduced break. Red on be446fb.
final class RewriteBreakerTests: XCTestCase {

    // MARK: - Planner: the transient target while a sentence is still streaming (ax mode)

    /// B1. The partial sentence is estimated one raw word per cleaned word. Dictation usually starts with
    /// fillers ("um so"), so the cleaned partial covers fewer raw words than the estimate skips and the tail
    /// repeats "it to". If the take ends mid-sentence (deadline, user typing), that repeat stays in the field.
    func testBreakAxPartialSentenceDuplicatesWordsAfterLeadingFillers() {
        var state = AlignState()
        let target = RewritePlanner.target(
            cleaned: "Send it to", streamEnded: false, raw: "um so send it to june on thursday", state: &state)
        XCTAssertEqual(target, "Send it to june on thursday", "raw words 'send it to' are already in the cleaned partial")
    }

    /// B2. The mirror case: the cleaned partial expands a raw word ("gonna" to "going to"), so it has more
    /// words than the raw it covers. The estimate skips "send", and the take ends with "send" gone.
    func testBreakAxPartialSentenceDropsWordsWhenCleanupExpandsContractions() {
        var state = AlignState()
        let target = RewritePlanner.target(
            cleaned: "I'm going to", streamEnded: false, raw: "im gonna send it", state: &state)
        XCTAssertEqual(target, "im gonna send it", "hold with no word lost: 'send it' has not been cleaned yet and must stay")
    }

    /// B3. A sentence that was completed early ("3." at the end of the stream so far) moves the raw cursor.
    /// When the same sentence grows ("3.5 dollars.") the sentence count does not change, so the cursor is
    /// never corrected and the raw words "five dollars" are shown again after the finished sentence.
    func testBreakCorrectedSentenceLeavesStaleRawTail() {
        var state = AlignState()
        let raw = "the price is three point five dollars"
        _ = RewritePlanner.target(cleaned: "The price is 3.", streamEnded: false, raw: raw, state: &state)
        let target = RewritePlanner.target(
            cleaned: "The price is 3.5 dollars.", streamEnded: false, raw: raw, state: &state)
        XCTAssertEqual(target, "The price is 3.5 dollars.", "the one complete sentence covers the whole raw text")
    }

    // MARK: - Reducer: Stage A text is not normalized

    /// B4. `.sttArrived` swaps the cloud transcript in as is. Only the LLM path goes through `normalize`.
    /// A newline in the transcript becomes a typed Return, which sends a Slack or Discord message. The plan's
    /// own invariant ("collapses all whitespace, including \n") is not applied to this swap.
    func testBreakSttStageAIsSwappedWithItsNewlineIntact() {
        var s = RewriteState(committed: "send it to jon")
        let effects = RewriteReducer.reduce(&s, .sttArrived("Send it to June.\nThanks for the update.", .assemblyai))
        guard case .swap(let target)? = effects.first else {
            return XCTFail("expected a Stage A swap, got \(effects)")
        }
        XCTAssertFalse(target.contains("\n"), "a newline typed into a chat field sends the message")
        XCTAssertEqual(target, "Send it to June. Thanks for the update.")
    }

    // MARK: - Guard: a truncated cleanup replaces the whole take

    /// B5. The guard only has an upper bound on length. A cleanup that keeps the first clause of a 40-word take
    /// and drops the rest shares 100 % of its words with the raw text, so it is accepted and the field keeps
    /// 8 words of 40. A cleanup that keeps under half of the raw words is a truncation, not a cleanup.
    func testBreakGuardAcceptsATruncatedCleanupThatDropsMostOfTheTake() {
        let raw = "so um I think we should send the quarterly report to june on thursday before the client meeting "
            + "and then review the budget with finance and also check the travel receipts and the hotel invoice "
            + "for last month"
        XCTAssertFalse(
            CleanupGuard.accept(raw: raw, cleaned: "Send the quarterly report to June on Thursday."),
            "8 of 40 raw words is a truncation and must not replace the take")
    }

    // MARK: - CJK

    /// B6. `CleanupGuard.words` splits on non-alphanumerics, and Chinese has no spaces, so a whole Chinese
    /// sentence is one "word". Any change to it shares 0 of 1 words and is rejected. Every Chinese cleanup is
    /// discarded, so the stage-B rewrite never happens for Chinese.
    func testBreakCjkCleanupIsAlwaysRejectedByTheGuard() throws {
        throw XCTSkip("out of scope per review r1: English-only take; CJK in FOLLOWUPS")
        XCTAssertTrue(
            CleanupGuard.accept(raw: "我想明天去北京开会", cleaned: "我明天去北京开会。"),
            "a one-character cleanup of a Chinese sentence must be accepted")
    }

    /// B7. `SentenceSplitter` only ends sentences at ASCII . ! ? and the ellipsis. Chinese uses 。！？, so the
    /// streamed cleanup never swaps sentence by sentence, and it waits for the end of the stream.
    func testBreakCjkSentencesAreNeverSplit() throws {
        throw XCTSkip("out of scope per review r1: English-only take; CJK in FOLLOWUPS")
        let result = SentenceSplitter.completeSentences(in: "我明天去北京开会。我们讨论预算。", streamEnded: false)
        XCTAssertEqual(result.sentences.count, 2)
    }

    // MARK: - Combining marks: the field's UTF-16 length drifts from state.committed

    /// B8. Apple's text is NFC ("é" is one scalar). An LLM may send the same letter decomposed ("e" plus a combining
    /// acute). The step keeps the NFC prefix from the field, but `committed` takes the NFD target. The field
    /// then holds 1 UTF-16 unit less than `committed`, so the next swap's caret check returns 4 and the take
    /// aborts with the text half cleaned.
    func testBreakNfdTargetOverNfcTextDriftsTheCaretBookkeeping() throws {
        throw XCTSkip("not a bug per review r1 for realistic NFC input; NFC normalize in FOLLOWUPS")
        let committed = "café x"
        let target = "cafe\u{301} y"
        guard let step = RewritePlanner.step(from: committed, to: target) else {
            return XCTFail("expected a step")
        }
        let field = step.apply(to: committed)
        XCTAssertEqual(
            field.utf16.count, target.utf16.count,
            "the field must hold exactly the UTF-16 length that state.committed records (caret check)")
    }

    // MARK: - Deletions: a step with an empty replacement

    /// The planner does emit empty-replacement steps for filler removal, e.g. "Hello um world" to "Hello world"
    /// or a trailing space left by the raw paste.
    private func deletionStep() -> RewriteStep? {
        RewritePlanner.step(from: "Hello um world", to: "Hello world")
    }

    private func helperSource() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The body of one helper function, from its signature up to the next `@objc func`.
    private func body(of signature: String, in source: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "@objc func")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// B9. `typeSwap` types `text` with `typeUnicode`, which posts nothing for an empty string. The shift+left
    /// selection of the old middle is left selected, so the filler stays in the field. The caret then no
    /// longer matches `committed`, or the next keys swap lands in the wrong place. The helper has no Delete
    /// (keyCode 51) path at all, so no empty-replacement step can remove text.
    /// Source-level: the helper runs in an AX-trusted process and cannot be exercised from XCTest.
    func testBreakKeysSwapCannotDeleteTextForAnEmptyReplacement() {
        XCTAssertEqual(deletionStep()?.newMiddle, "", "precondition: the planner emits a deletion here")
        let typeSwap = body(of: "func typeSwap(", in: helperSource())
        XCTAssertFalse(typeSwap.isEmpty, "precondition: typeSwap exists")
        XCTAssertTrue(typeSwap.contains("51"), "typeSwap must press Delete (keyCode 51) to remove the old middle")
    }

    /// B10. Same break in `axSelectThenType`: the selection is set and read back, `typeUnicode("")` posts
    /// nothing, and the caret is then set to `caretAfter`. The old middle is still in the field, and the
    /// caret is inside the next word.
    func testBreakAxSelectThenTypeCannotDeleteTextForAnEmptyReplacement() {
        XCTAssertEqual(deletionStep()?.newMiddle, "", "precondition: the planner emits a deletion here")
        let fn = body(of: "func axSelectThenType(", in: helperSource())
        XCTAssertFalse(fn.isEmpty, "precondition: axSelectThenType exists")
        XCTAssertTrue(fn.contains("51"), "axSelectThenType must press Delete (keyCode 51) when the text is empty")
    }
}
