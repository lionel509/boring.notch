import Foundation
import XCTest
@testable import VoiceDictationLogic

final class EnrollmentLogicTests: XCTestCase {
    private func run(_ events: [EnrollmentLogic.Event]) -> EnrollmentLogic.State {
        var state = EnrollmentLogic.State()
        for event in events { EnrollmentLogic.reduce(&state, event) }
        return state
    }

    /// A clip of `seconds` at a constant level: alternating samples whose RMS is `dBFS`, at 16 kHz.
    private func tone(dBFS: Double, seconds: Double) -> [Float] {
        let amplitude = Float(pow(10, dBFS / 20))
        return (0..<Int(seconds * 16_000)).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    /// Three prompts read and accepted: the state is ready to score.
    private var threeAccepted: [EnrollmentLogic.Event] {
        [.start, .stop(accepted: true), .start, .stop(accepted: true), .start, .stop(accepted: true)]
    }

    // MARK: clip gate

    func testSpeechAtMinus30IsAccepted() {
        XCTAssertTrue(EnrollmentLogic.clipAccepted(tone(dBFS: -30, seconds: 1)))
    }

    func testHalfASecondOfSpeechIsEnough() {
        XCTAssertTrue(EnrollmentLogic.clipAccepted(tone(dBFS: -30, seconds: 0.5)))
    }

    func testFourTenthsOfASecondIsNotEnough() {
        XCTAssertFalse(EnrollmentLogic.clipAccepted(tone(dBFS: -30, seconds: 0.4)))
    }

    func testOneLoudClickDoesNotPassAQuietPrompt() {
        var samples = tone(dBFS: -50, seconds: 8)
        let clickStart = 40_000 // on a 320-sample frame boundary
        for i in clickStart..<(clickStart + 320) { samples[i] = i % 2 == 0 ? 0.3 : -0.3 }
        XCTAssertFalse(EnrollmentLogic.clipAccepted(samples), "a 20 ms click must not lift a -50 dBFS prompt")
    }

    func testSilenceAndEmptyAreRejected() {
        XCTAssertFalse(EnrollmentLogic.clipAccepted([]))
        XCTAssertFalse(EnrollmentLogic.clipAccepted(tone(dBFS: -60, seconds: 8)))
    }

    // MARK: step transitions

    func testStartMovesFromPromptToRecording() {
        let state = run([.start])
        XCTAssertEqual(state.step, .recording(0))
        XCTAssertNil(state.message)
    }

    func testStartOutsideAPromptChangesNothing() {
        XCTAssertEqual(run(threeAccepted + [.start]).step, .computing)
        XCTAssertEqual(run([.stop(accepted: true)]).step, .prompt(0), "a stop without a start changes nothing")
    }

    func testAcceptedPromptAdvancesAndCountsTheClip() {
        let state = run([.start, .stop(accepted: true)])
        XCTAssertEqual(state.step, .prompt(1))
        XCTAssertEqual(state.clips, 1)
        XCTAssertEqual(state.quietAttempts, 0)
        XCTAssertNil(state.message)
    }

    func testThirdAcceptedPromptStartsComputing() {
        let state = run(threeAccepted)
        XCTAssertEqual(state.step, .computing)
        XCTAssertEqual(state.clips, EnrollmentLogic.promptCount)
    }

    func testQuietPromptRepeatsWithTheMessage() {
        let state = run([.start, .stop(accepted: false)])
        XCTAssertEqual(state.step, .prompt(0), "the same prompt is asked again")
        XCTAssertEqual(state.message, EnrollmentLogic.closerMessage)
        XCTAssertEqual(state.clips, 0)
        XCTAssertEqual(state.quietAttempts, 1)
    }

    func testRetryLimitFailsAfterRepeatedQuietTakes() {
        var events: [EnrollmentLogic.Event] = []
        for _ in 0..<EnrollmentLogic.maxQuietAttempts { events += [.start, .stop(accepted: false)] }
        XCTAssertEqual(run(events).step, .failed(EnrollmentLogic.tryAgainMessage))
    }

    func testAcceptedPromptResetsTheQuietCount() {
        var events: [EnrollmentLogic.Event] = []
        for _ in 0..<(EnrollmentLogic.maxQuietAttempts - 1) { events += [.start, .stop(accepted: false)] }
        events += [.start, .stop(accepted: true)]
        let state = run(events)
        XCTAssertEqual(state.step, .prompt(1))
        XCTAssertEqual(state.quietAttempts, 0)
    }

    func testScoredWithoutOutlierFinishes() {
        XCTAssertEqual(run(threeAccepted + [.scored(outlier: nil)]).step, .done)
    }

    func testScoredOutsideComputingChangesNothing() {
        XCTAssertEqual(run([.scored(outlier: nil)]).step, .prompt(0))
    }

    func testFailFromAnyStepShowsTheReason() {
        XCTAssertEqual(run([.start, .fail("No microphone")]).step, .failed("No microphone"))
    }

    func testCloseReturnsToTheFirstPrompt() {
        let state = run([.start, .stop(accepted: true), .start, .close])
        XCTAssertEqual(state, EnrollmentLogic.State())
    }

    func testHappyPathEndsDone() {
        let state = run(threeAccepted + [.scored(outlier: nil)])
        XCTAssertEqual(state.step, .done)
        XCTAssertEqual(state.clips, 3)
    }

    // MARK: clip that does not match the others

    func testOutlierClipIsReadAgain() {
        let state = run(threeAccepted + [.scored(outlier: 2)])
        XCTAssertEqual(state.step, .prompt(2))
        XCTAssertEqual(state.clips, 2)
        XCTAssertEqual(state.message, EnrollmentLogic.inconsistentMessage)
        XCTAssertTrue(state.redo)
    }

    func testReReadClipReturnsToScoring() {
        let state = run(threeAccepted + [.scored(outlier: 2), .start, .stop(accepted: true)])
        XCTAssertEqual(state.step, .computing)
        XCTAssertEqual(state.clips, 3)
        XCTAssertFalse(state.redo)
    }

    func testOutliersCountAgainstTheRetryLimit() {
        // The cap is three re-reads: the fourth outlier is refused.
        var events = threeAccepted
        for _ in 0..<EnrollmentLogic.maxQuietAttempts {
            events += [.scored(outlier: 2), .start, .stop(accepted: true)]
        }
        XCTAssertEqual(run(events).step, .computing, "three re-reads are allowed")
        XCTAssertEqual(run(events + [.scored(outlier: 2)]).step, .failed(EnrollmentLogic.tryAgainMessage))
    }

    func testThreeRedosAreAllowedBeforeTheCapFails() {
        let events: [EnrollmentLogic.Event] = threeAccepted + [
            .scored(outlier: 2), .start, .stop(accepted: true),
            .scored(outlier: 2), .start, .stop(accepted: true),
            .scored(outlier: 2),
        ]
        XCTAssertEqual(run(events).step, .prompt(2), "the third redo was refused")
    }

    // MARK: voiceprint

    func testConsistentClipsHaveNoOutlier() {
        XCTAssertNil(EnrollmentLogic.inconsistentClip([[1, 0, 0], [1, 0.05, 0], [0.98, 0.1, 0]]))
    }

    func testOtherVoiceAtTheMeasuredCosineIsTheOutlier() {
        let other: [Float] = [0.26, Float((1 - 0.26 * 0.26).squareRoot()), 0]
        XCTAssertEqual(EnrollmentLogic.inconsistentClip([[1, 0, 0], [1, 0, 0], other]), 2)
    }

    func testAgreementBarIsPointFourFive() {
        XCTAssertEqual(EnrollmentLogic.minAgreement, 0.45)
    }

    func testAgreeingEmbeddingsPass() {
        XCTAssertTrue(EnrollmentLogic.agrees([[1, 0, 0], [1, 0.05, 0], [0.98, 0.1, 0]]))
    }

    func testOneOutlierFailsAgreement() {
        XCTAssertFalse(EnrollmentLogic.agrees([[1, 0, 0], [1, 0, 0], [0, 0, 1]]))
    }

    func testAgreementNeedsTwoEmbeddings() {
        XCTAssertFalse(EnrollmentLogic.agrees([[1, 0, 0]]))
        XCTAssertFalse(EnrollmentLogic.agrees([]))
    }

    func testVoiceprintIsTheCentroidOfAgreeingEmbeddings() throws {
        let print = try XCTUnwrap(EnrollmentLogic.assemble([[1, 0, 0], [1, 0, 0], [1, 0, 0]]))
        XCTAssertEqual(print.count, 3)
        XCTAssertEqual(print[0], 1, accuracy: 1e-6)
        XCTAssertEqual(print[1], 0, accuracy: 1e-6)
        XCTAssertEqual(print[2], 0, accuracy: 1e-6)
    }

    func testVoiceprintIsNilWhenTheClipsDisagree() {
        XCTAssertNil(EnrollmentLogic.assemble([[1, 0, 0], [1, 0, 0], [0, 0, 1]]))
    }

    func testVoiceprintIsNilForAnotherVoiceAtTheMeasuredCosine() {
        let other: [Float] = [0.26, Float((1 - 0.26 * 0.26).squareRoot()), 0]
        XCTAssertNil(EnrollmentLogic.assemble([[1, 0, 0], [1, 0, 0], other]))
    }
}
