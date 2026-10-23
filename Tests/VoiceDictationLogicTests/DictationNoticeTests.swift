import Foundation
import XCTest
@testable import VoiceDictationLogic

/// r5 notice: a failed or too-short take says one short line beside the notch (the song-change
/// style sneak peek) instead of text inside the closed strip. These pin the wording per outcome,
/// the 18-character label rule, and the hold threshold for the too-short notice.
final class DictationNoticeTests: XCTestCase {
    private let allOutcomes: [TakeOutcome] = [
        .pasted, .discarded, .nothingHeard, .micSilent, .noAudio, .accessDenied, .failed,
    ]

    private let allMessages = [
        "",
        "Needs macOS 26",
        "Copied (clipboard replaced). Helper not responding",
        "Copied (clipboard replaced). Allow Accessibility to paste",
        "Copied (clipboard replaced). Helper slow, paste may still land",
        "Copied (clipboard replaced). Paste failed",
        "Clipboard changed. Not pasted",
        "Mic access off. See Settings",
        "Mic blocked. See Settings",
        "No speech",
        "No audio from the mic",
        "Speech model still downloading",
    ]

    func testTooShortTapSaysHoldLonger() {
        XCTAssertEqual(
            DictationNotices.notice(for: .discarded, message: ""),
            DictationNotice(label: "Hold fn longer", detail: "", icon: "mic"))
    }

    func testNothingHeardSaysDidntCatchThat() {
        XCTAssertEqual(
            DictationNotices.notice(for: .nothingHeard, message: "No speech"),
            DictationNotice(label: "Didn't catch that", detail: "", icon: "mic.slash"))
    }

    func testNoAudioSaysMicUnavailable() {
        XCTAssertEqual(
            DictationNotices.notice(for: .noAudio, message: "No audio from the mic"),
            DictationNotice(label: "Mic unavailable", detail: "", icon: "mic.slash"))
    }

    func testMicSilentPointsAtSettings() {
        XCTAssertEqual(
            DictationNotices.notice(for: .micSilent, message: "Mic blocked. See Settings"),
            DictationNotice(label: "Mic blocked", detail: "Settings", icon: "mic.slash"))
    }

    func testAccessDeniedPointsAtSettings() {
        XCTAssertEqual(
            DictationNotices.notice(for: .accessDenied, message: "Mic access off. See Settings"),
            DictationNotice(label: "Allow mic access", detail: "Settings", icon: "mic.slash"))
    }

    func testMacOS26Notice() {
        XCTAssertEqual(
            DictationNotices.notice(for: .failed, message: "Needs macOS 26"),
            DictationNotice(label: "Needs macOS 26", detail: "", icon: "exclamationmark.circle"))
    }

    func testPasteFailureSaysCopiedNotPasted() {
        let paste = DictationNotice(label: "Copied, not pasted", detail: "⌘V", icon: "doc.on.clipboard")
        XCTAssertEqual(
            DictationNotices.notice(for: .failed, message: "Copied (clipboard replaced). Paste failed"), paste)
        XCTAssertEqual(
            DictationNotices.notice(for: .failed, message: "Clipboard changed. Not pasted"), paste)
        XCTAssertEqual(
            DictationNotices.notice(for: .failed, message: "Copied (clipboard replaced). Helper not responding"), paste)
    }

    func testAccessibilityPasteFailureNamesTheGrant() {
        XCTAssertEqual(
            DictationNotices.notice(
                for: .failed, message: "Copied (clipboard replaced). Allow Accessibility to paste"),
            DictationNotice(label: "Copied, not pasted", detail: "Allow Accessibility", icon: "doc.on.clipboard"))
    }

    func testAnythingElseIsDictationFailed() {
        XCTAssertEqual(
            DictationNotices.notice(for: .failed, message: "Engine: restarting"),
            DictationNotice(label: "Dictation failed", detail: "", icon: "exclamationmark.circle"))
    }

    func testSuccessfulPasteHasNoNotice() {
        XCTAssertNil(DictationNotices.notice(for: .pasted, message: ""))
    }

    /// Every label is short enough for the one-line announcement headline.
    func testEveryLabelIsAtMostEighteenCharacters() {
        for outcome in allOutcomes {
            for message in allMessages {
                guard let notice = DictationNotices.notice(for: outcome, message: message) else { continue }
                XCTAssertLessThanOrEqual(
                    notice.label.count, 18,
                    "\(outcome) / \(message): '\(notice.label)' is \(notice.label.count) characters")
            }
        }
    }

    /// The too-short notice only fires for a hold of at least 0.12 s, so a bare fn or globe
    /// tap that the system uses for something else stays silent.
    func testTooShortNoticeNeedsAtLeastTwelveHundredthsOfASecond() {
        XCTAssertEqual(DictationNotices.minDiscardHold, 0.12, accuracy: 0.0001)
        XCTAssertFalse(DictationNotices.isDiscardWorthNotice(heldFor: 0))
        XCTAssertFalse(DictationNotices.isDiscardWorthNotice(heldFor: 0.11))
        XCTAssertTrue(DictationNotices.isDiscardWorthNotice(heldFor: 0.12))
        XCTAssertTrue(DictationNotices.isDiscardWorthNotice(heldFor: 0.4))
    }
}

/// Source-reading checks: the manager posts the notice through the coordinator, the closed strip
/// draws no failure text, and `.dictation` is an announcement like `.systemAlert`.
final class DictationNoticeSourceTests: XCTestCase {
    func testFailPostsTheNoticeInsteadOfTheStripText() throws {
        let text = try appSource("boringNotch/Voice/VoiceDictationManager.swift")
        let start = try XCTUnwrap(text.range(of: "private func fail(_ message: String"), "fail( moved; re-check this test")
        let end = try XCTUnwrap(text.range(of: "private func scheduleReset", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("toggleSneakPeek("), "fail( no longer posts the sneak peek")
        XCTAssertTrue(body.contains("type: .dictation"), "fail( does not post the .dictation notice")
        XCTAssertTrue(body.contains("DictationNotices.notice("), "fail( does not map the outcome through DictationNotices")
        XCTAssertTrue(body.contains("state = .idle"), "fail( does not return the strip to idle")
        XCTAssertFalse(body.contains("state = .failed(message)"), "fail( still puts the message into the strip")
    }

    func testStripDrawsNoFailureText() throws {
        let text = try appSource("boringNotch/Voice/VoiceDictationLiveActivity.swift")
        XCTAssertFalse(text.contains("case .failed(let message)"), "the strip still reads the failure message")
        XCTAssertFalse(text.contains("failureCell("), "the strip still draws a failure text cell")
        XCTAssertFalse(text.contains("DictationStrip.headline("), "the strip still turns a message into a headline")
        XCTAssertFalse(text.contains("exclamationmark"), "the strip still draws the failure exclamation mark")
    }

    func testDictationIsAnAnnouncement() throws {
        let text = try appSource("boringNotch/BoringViewCoordinator.swift")
        let start = try XCTUnwrap(text.range(of: "var isAnnouncement: Bool"), "isAnnouncement moved; re-check this test")
        let end = try XCTUnwrap(text.range(of: "default: false", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".dictation"), ".dictation is not in isAnnouncement")
        XCTAssertTrue(text.contains("case dictation"), "SneakContentType has no .dictation case")
    }

    private func appSource(_ relative: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/DictationNoticeTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
