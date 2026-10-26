import XCTest
@testable import VoiceDictationLogic

/// U4 / I4 (never lose a take): the pure reducer ends every path in exactly one `.finish`, and the field
/// ends with one of {LLM text that passed the guard, STT text, Apple's final, Apple's raw}.
final class RewriteStateTests: XCTestCase {
    private let raw = "um send it to jon"
    private let stt = "Send it to June."

    /// Stage A: STT text arrives, swaps in, streams; the swap acknowledgement is the next event.
    private func afterSTT(_ s: inout RewriteState) {
        _ = RewriteReducer.reduce(&s, .sttArrived(stt, .assemblyai))
        _ = RewriteReducer.reduce(&s, .swapResult(0))
    }

    func testHappyPathEndsCompleted() {
        var s = RewriteState(committed: raw)
        XCTAssertEqual(
            RewriteReducer.reduce(&s, .sttArrived(stt, .assemblyai)),
            [.swap(to: stt), .startStream(input: stt)])
        XCTAssertEqual(RewriteReducer.reduce(&s, .swapResult(0)), [])
        XCTAssertEqual(RewriteReducer.reduce(&s, .tokens("Send it to June.")), [])
        XCTAssertEqual(RewriteReducer.reduce(&s, .streamEnded), [.finish(.completed)])
        XCTAssertEqual(s.committed, stt)
        XCTAssertEqual(s.outcome, .completed)
        XCTAssertEqual(s.stage, .ended)
    }

    func testCleanupThatDiffersFromStageAIsSwappedInAtStreamEnd() {
        var s = RewriteState(committed: raw)
        afterSTT(&s)
        _ = RewriteReducer.reduce(&s, .tokens("Send it to June!"))
        XCTAssertEqual(RewriteReducer.reduce(&s, .streamEnded), [.swap(to: "Send it to June!")])
        XCTAssertEqual(RewriteReducer.reduce(&s, .swapResult(0)), [.finish(.completed)])
        XCTAssertEqual(s.committed, "Send it to June!")
    }

    func testSTTFailedThenAppleFinalStreamsFromApple() {
        var s = RewriteState(committed: raw)
        XCTAssertEqual(RewriteReducer.reduce(&s, .sttFailed), [])
        XCTAssertEqual(
            RewriteReducer.reduce(&s, .appleFinal("send it to jon")),
            [.swap(to: "send it to jon"), .startStream(input: "send it to jon")])
        XCTAssertEqual(s.stageAText, "send it to jon")
    }

    func testAppleFinalArrivingFirstWaitsForTheSTTFailure() {
        var s = RewriteState(committed: raw)
        XCTAssertEqual(RewriteReducer.reduce(&s, .appleFinal("send it to jon")), [])
        XCTAssertEqual(
            RewriteReducer.reduce(&s, .sttFailed),
            [.swap(to: "send it to jon"), .startStream(input: "send it to jon")])
    }

    func testSTTAndAppleBothMissingFailsAndLeavesTheRawText() {
        var s = RewriteState(committed: raw)
        XCTAssertEqual(RewriteReducer.reduce(&s, .sttFailed), [])
        XCTAssertEqual(RewriteReducer.reduce(&s, .appleFinal("")), [.finish(.failed)])
        XCTAssertEqual(s.committed, raw)
        XCTAssertEqual(s.outcome, .failed)
    }

    func testUserTouchedMidStreamAbortsAndNothingAfterwardRuns() {
        var s = RewriteState(committed: raw)
        afterSTT(&s)
        _ = RewriteReducer.reduce(&s, .tokens("Send it"))
        XCTAssertEqual(RewriteReducer.reduce(&s, .userTouched), [.finish(.aborted)])
        XCTAssertEqual(RewriteReducer.reduce(&s, .tokens("Send it to")), [])
        XCTAssertEqual(RewriteReducer.reduce(&s, .streamEnded), [])
        XCTAssertEqual(RewriteReducer.reduce(&s, .swapResult(0)), [])
        XCTAssertEqual(RewriteReducer.reduce(&s, .deadline), [])
        XCTAssertEqual(s.outcome, .aborted)
    }

    func testDeadlineMidStreamTimesOutAndNothingAfterwardRuns() {
        var s = RewriteState(committed: raw)
        afterSTT(&s)
        XCTAssertEqual(RewriteReducer.reduce(&s, .deadline), [.finish(.timedOut)])
        XCTAssertEqual(RewriteReducer.reduce(&s, .tokens("Send")), [])
        XCTAssertEqual(RewriteReducer.reduce(&s, .streamEnded), [])
        XCTAssertEqual(s.outcome, .timedOut)
    }

    func testSwapResultThreeFails() {
        var s = RewriteState(committed: raw)
        _ = RewriteReducer.reduce(&s, .sttArrived(stt, .assemblyai))
        XCTAssertEqual(RewriteReducer.reduce(&s, .swapResult(3)), [.finish(.failed)])
    }

    func testSwapResultFiveIsAnAbort() {
        var s = RewriteState(committed: raw)
        _ = RewriteReducer.reduce(&s, .sttArrived(stt, .assemblyai))
        XCTAssertEqual(RewriteReducer.reduce(&s, .swapResult(5)), [.finish(.aborted)])
    }

    func testStreamFailureBeforeFirstTokenStartsFoundationCleanup() {
        var s = RewriteState(committed: raw)
        afterSTT(&s)
        XCTAssertEqual(RewriteReducer.reduce(&s, .streamFailed), [.startFoundation(input: stt)])
        XCTAssertEqual(
            RewriteReducer.reduce(&s, .foundationResult("Send it to June!")),
            [.swap(to: "Send it to June!")])
        XCTAssertEqual(RewriteReducer.reduce(&s, .swapResult(0)), [.finish(.completed)])
    }

    func testFoundationReturningNilKeepsStageATextAndCompletes() {
        var s = RewriteState(committed: raw)
        afterSTT(&s)
        _ = RewriteReducer.reduce(&s, .streamFailed)
        XCTAssertEqual(RewriteReducer.reduce(&s, .foundationResult(nil)), [.finish(.completed)])
        XCTAssertEqual(s.committed, stt)
    }

    func testStreamFailureAfterTokensRevertsToStageA() {
        var s = RewriteState(committed: raw)
        afterSTT(&s)
        _ = RewriteReducer.reduce(&s, .tokens("Send"))
        XCTAssertEqual(RewriteReducer.reduce(&s, .streamFailed), [.revert(to: stt)])
        XCTAssertEqual(RewriteReducer.reduce(&s, .swapResult(0)), [.finish(.reverted)])
        XCTAssertEqual(s.committed, stt)
    }

    func testFocusedFieldDecodesTheHelperJSON() throws {
        let json = #"{"pid":412,"bundle":"com.apple.TextEdit","role":"AXTextArea","secure":false,"caret":5,"rangeSettable":true,"textSettable":false}"#
        let field = try JSONDecoder().decode(FocusedField.self, from: Data(json.utf8))
        XCTAssertEqual(
            field,
            FocusedField(pid: 412, bundle: "com.apple.TextEdit", role: "AXTextArea", secure: false,
                         caret: 5, rangeSettable: true, textSettable: false))
        let back = try JSONDecoder().decode(FocusedField.self, from: JSONEncoder().encode(field))
        XCTAssertEqual(back, field)

        let noBundle = #"{"pid":1,"bundle":null,"role":"AXTextField","secure":true,"caret":-1,"rangeSettable":false,"textSettable":false}"#
        let secure = try JSONDecoder().decode(FocusedField.self, from: Data(noBundle.utf8))
        XCTAssertNil(secure.bundle)
        XCTAssertTrue(secure.secure)
    }

    /// I4 fuzz: random event sequences never run effects after `.finish`, finish at most once,
    /// and leave `committed` at one of the initial text, Stage A, or a target the reducer swapped to.
    func testFuzzNothingRunsAfterFinishAndCommittedIsAKnownText() {
        var rng = ReducerRNG(seed: 7)
        let events: [RewriteEvent] = [
            .sttArrived("send it to june.", .assemblyai), .sttFailed, .appleFinal("send it to jon"),
            .tokens("Send it"), .tokens("Send it to June."), .streamEnded, .streamFailed,
            .foundationResult(nil), .foundationResult("Send it to June."), .swapResult(0),
            .swapResult(3), .swapResult(5), .userTouched, .deadline, .cancelled,
        ]
        for _ in 0..<200 {
            var s = RewriteState(committed: raw)
            var known: Set<String> = [raw]
            var finishes = 0
            for _ in 0..<rng.int(1, 12) {
                let event = events[rng.int(0, events.count - 1)]
                let wasEnded = s.stage == .ended
                let before = s
                let effects = RewriteReducer.reduce(&s, event)
                for effect in effects {
                    switch effect {
                    case .swap(let to), .revert(let to): known.insert(to)
                    case .finish: finishes += 1
                    default: break
                    }
                }
                if wasEnded {
                    XCTAssertEqual(effects, [])
                    XCTAssertEqual(s, before)
                }
            }
            if let stageA = s.stageAText { known.insert(stageA) }
            XCTAssertLessThanOrEqual(finishes, 1)
            XCTAssertTrue(known.contains(s.committed), s.committed)
        }
    }
}

/// Deterministic generator local to this file.
private struct ReducerRNG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        lo + Int(next() % UInt64(hi - lo + 1))
    }
}
