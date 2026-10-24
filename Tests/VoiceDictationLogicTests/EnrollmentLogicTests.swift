import Foundation
import XCTest
@testable import VoiceDictationLogic

final class EnrollmentLogicTests: XCTestCase {
    private let loud: Float = -20
    private let quiet: Float = -50

    private func run(_ events: [EnrollmentLogic.Event]) -> EnrollmentLogic.State {
        var state = EnrollmentLogic.State()
        for event in events { EnrollmentLogic.reduce(&state, event) }
        return state
    }

    // MARK: level gate

    func testLevelGateKeepsLoudEnoughPrompts() {
        XCTAssertTrue(EnrollmentLogic.levelAccepted(-20))
        XCTAssertTrue(EnrollmentLogic.levelAccepted(-35), "the boundary is accepted")
        XCTAssertFalse(EnrollmentLogic.levelAccepted(-35.1))
        XCTAssertFalse(EnrollmentLogic.levelAccepted(-.infinity), "an empty or silent take is too quiet")
    }

    // MARK: step transitions

    func testStartMovesFromPromptToRecording() {
        let state = run([.start])
        XCTAssertEqual(state.step, .recording(0))
        XCTAssertNil(state.message)
    }

    func testStartOutsideAPromptChangesNothing() {
        let computing = run([.start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud)])
        XCTAssertEqual(computing.step, .computing)
        XCTAssertEqual(run([.start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud), .start]).step, .computing)
        XCTAssertEqual(run([.stop(levelDBFS: loud)]).step, .prompt(0), "a stop without a start changes nothing")
    }

    func testLoudPromptAdvancesAndCountsTheClip() {
        let state = run([.start, .stop(levelDBFS: loud)])
        XCTAssertEqual(state.step, .prompt(1))
        XCTAssertEqual(state.clips, 1)
        XCTAssertEqual(state.quietAttempts, 0)
        XCTAssertNil(state.message)
    }

    func testThirdLoudPromptStartsComputing() {
        let state = run([.start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud)])
        XCTAssertEqual(state.step, .computing)
        XCTAssertEqual(state.clips, EnrollmentLogic.promptCount)
    }

    func testQuietPromptRepeatsWithTheMessage() {
        let state = run([.start, .stop(levelDBFS: quiet)])
        XCTAssertEqual(state.step, .prompt(0), "the same prompt is asked again")
        XCTAssertEqual(state.message, EnrollmentLogic.closerMessage)
        XCTAssertEqual(state.clips, 0)
        XCTAssertEqual(state.quietAttempts, 1)
    }

    func testRetryLimitFailsAfterRepeatedQuietTakes() {
        var events: [EnrollmentLogic.Event] = []
        for _ in 0..<EnrollmentLogic.maxQuietAttempts { events += [.start, .stop(levelDBFS: quiet)] }
        let state = run(events)
        XCTAssertEqual(state.step, .failed(EnrollmentLogic.tryAgainMessage))
    }

    func testLoudPromptResetsTheQuietCount() {
        var events: [EnrollmentLogic.Event] = []
        for _ in 0..<(EnrollmentLogic.maxQuietAttempts - 1) { events += [.start, .stop(levelDBFS: quiet)] }
        events += [.start, .stop(levelDBFS: loud)]
        let state = run(events)
        XCTAssertEqual(state.step, .prompt(1))
        XCTAssertEqual(state.quietAttempts, 0)
    }

    func testScoredTrueFinishesAndFalseFails() {
        let base: [EnrollmentLogic.Event] = [.start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud), .start, .stop(levelDBFS: loud)]
        XCTAssertEqual(run(base + [.scored(true)]).step, .done)
        XCTAssertEqual(run(base + [.scored(false)]).step, .failed(EnrollmentLogic.tryAgainMessage))
    }

    func testScoredOutsideComputingChangesNothing() {
        XCTAssertEqual(run([.scored(true)]).step, .prompt(0))
    }

    func testFailFromAnyStepShowsTheReason() {
        XCTAssertEqual(run([.start, .fail("No microphone")]).step, .failed("No microphone"))
    }

    func testCloseReturnsToTheFirstPrompt() {
        let state = run([.start, .stop(levelDBFS: loud), .start, .close])
        XCTAssertEqual(state, EnrollmentLogic.State())
    }

    func testHappyPathEndsDone() {
        let state = run([
            .start, .stop(levelDBFS: -18),
            .start, .stop(levelDBFS: -25),
            .start, .stop(levelDBFS: -30),
            .scored(true),
        ])
        XCTAssertEqual(state.step, .done)
        XCTAssertEqual(state.clips, 3)
    }

    // MARK: voiceprint

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
}
