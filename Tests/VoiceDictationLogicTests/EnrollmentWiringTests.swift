import Foundation
import XCTest
@testable import VoiceDictationLogic

/// Review fixes on #17 U3 (PR #26). The app has no XCTest target, so the wiring is pinned in the source, and the
/// pure decision is tested directly.
final class EnrollmentWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // Finding 1: the stored pause flag is cleared once at launch.

    func testPausesMediaMigrationRunsOnlyUntilItIsDone() {
        XCTAssertTrue(PausesMediaMigration.shouldReset(alreadyDone: false))
        XCTAssertFalse(PausesMediaMigration.shouldReset(alreadyDone: true))
    }

    func testLaunchClearsThePausesMediaKeyOnce() throws {
        let app = try source("boringNotch/boringNotchApp.swift")
        XCTAssertTrue(app.contains("PausesMediaMigration.shouldReset(alreadyDone:"),
                      "launch does not run the one-time pause-flag migration")
        XCTAssertTrue(app.contains("Defaults.reset(.dictationPausesMedia)"),
                      "launch does not clear a stored dictationPausesMedia")
    }

    // Finding 2: enrolment picks the take's mono source, not channel 0.

    func testEnrolmentUsesTheTakesChannelPick() throws {
        let enrollment = try source("boringNotch/Voice/VoiceEnrollment.swift")
        XCTAssertTrue(enrollment.contains("takeSource(for:"), "enrolment does not use the take's takeSource")
        XCTAssertTrue(enrollment.contains("takeMonoBuffer("), "enrolment does not use the take's takeMonoBuffer")
        XCTAssertFalse(enrollment.contains("channelZero"), "enrolment still records channel 0 unconditionally")
    }

    // Round 3: the demo can see the channel and the level of every enrolment prompt.

    func testEnrolmentLogsEachPromptThroughDictationLog() throws {
        let enrollment = try source("boringNotch/Voice/VoiceEnrollment.swift")
        XCTAssertTrue(enrollment.contains("DictationLog.take("), "enrolment does not log through DictationLog")
        XCTAssertTrue(enrollment.contains("micChannel"), "enrolment does not report the picked channel")
    }

    func testTheTakeReportsItsPickedChannel() throws {
        let session = try source("boringNotch/Voice/SpeechAnalyzerSession.swift")
        XCTAssertTrue(session.contains("report.micChannel ="), "the take does not report the picked channel")
    }

    // Finding 3: the tap is removed from the node it was installed on.

    func testEnrolmentRemovesItsTapFromTheTapNode() throws {
        let enrollment = try source("boringNotch/Voice/VoiceEnrollment.swift")
        XCTAssertTrue(enrollment.contains("tapNode?.removeTap(onBus: 0)"),
                      "teardown does not remove the tap from the node it was installed on")
        XCTAssertFalse(enrollment.contains("engine.inputNode.removeTap"),
                       "teardown removes the tap from the input node, not the effect node")
    }
}
