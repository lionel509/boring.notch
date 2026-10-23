import XCTest

/// Breaker round 5 on PR #23 (head a2f72dd). Source-level, because the app files are not compiled by this package.
final class BreakerRound5CallPromptTests: XCTestCase {

    /// R5-1: a prompt that is up when fn dictation is turned off must not be redrawn without its hint and left on screen.
    func testPromptUpWhenDictationTurnedOffDoesNotStayDrawn() throws {
        let text = try appSource("boringNotch/Voice/CallDetector.swift")
        let body = try section(text, from: "private func renderPendingPrompt()", to: "/// Times out the prompt")
        XCTAssertTrue(body.contains("dictateWithFn"),
                      "renderPendingPrompt draws with no dictateWithFn gate, so a prompt already up stays on screen after fn dictation is turned off")
    }

    /// R5-2: turning fn dictation back on must re-evaluate the live calls, so a call that is still live is asked about.
    func testTurningDictationBackOnReevaluatesLiveCalls() throws {
        let text = try appSource("boringNotch/Voice/CallDetector.swift")
        XCTAssertTrue(text.contains("Defaults.publisher(.dictateWithFn)") || text.contains("Defaults.updates(.dictateWithFn)"),
                      "CallDetector never observes dictateWithFn, so turning fn dictation back on does not re-ask about a live call")
    }

    private func section(_ text: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(text.range(of: start), "\(start) moved; re-check this test")
        let upper = try XCTUnwrap(text.range(of: end, range: lower.upperBound..<text.endIndex), "\(end) moved; re-check this test")
        return String(text[lower.lowerBound..<upper.lowerBound])
    }

    private func appSource(_ relative: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/BreakerRound5CallPromptTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
