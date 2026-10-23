import XCTest

/// Breaker round 4 on PR #23 (head d7da3e1). Source-level, because the app files are not compiled by this package.
final class BreakerRound4CallPromptTests: XCTestCase {

    /// R4-1: the fn+Y/N/D hint must follow the live fn mode while a prompt is up, not the mode at show time.
    func testHintFollowsFnModeWhilePromptIsUp() throws {
        let text = try appSource("boringNotch/Voice/CallDetector.swift")
        XCTAssertTrue(text.contains("FnKeyMonitor.shared.$mode"),
                      "CallDetector never observes FnKeyMonitor.mode, so the fn+Y/N/D hint is frozen at show time")
    }

    /// R4-2: with fn dictation off in Settings, no prompt shows, because nothing it offers can start.
    func testNoCallPromptWhenFnDictationIsTurnedOff() throws {
        let text = try appSource("boringNotch/Voice/CallDetector.swift")
        let start = try XCTUnwrap(text.range(of: "case .show(let call):"), "show effect moved; re-check this test")
        let end = try XCTUnwrap(text.range(of: "case .hide:", range: start.upperBound..<text.endIndex),
                                "hide effect moved; re-check this test")
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("dictateWithFn"),
                      "the show effect never checks dictateWithFn, so with fn dictation off a prompt shows that can be neither answered nor muted")
    }

    private func appSource(_ relative: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/BreakerRound4CallPromptTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
