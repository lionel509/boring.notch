import XCTest
@testable import VoiceDictationLogic

/// Breaker round 9 on PR #31 (comment 6477462406): the round-8 outcome logging.
/// Source-pinned like GhostTextWiringTests, because the app target is not in the SwiftPM package.
final class GhostTextBreakerR9Tests: XCTestCase {

    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    /// Break a (no-caret branch): the same double line. The branch must log its reason and hide without a nested
    /// `handle(.focusChanged)`.
    func testBreakR9_1bNoCaretOverlayLogsOnlyOneLine() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let overlay = section(manager, from: "private func showOverlay(", to: "// MARK: - Accept")
        let noCaret = section(overlay, from: "overlayNoCaret)", to: "let font = Self.overlayFont(")
        XCTAssertFalse(noCaret.contains("handle(.focusChanged)"),
                       "after logging overlayNoCaret, handle(.focusChanged) runs while showing and logs 'event=dismissed'")
    }

    /// Break b: a fetch cancelled after the model call (the user typed while the model thought) returns with no
    /// line at all. The round-8 invariant is one line for every outcome after .call.
    func testBreakR9_2CancelledAfterCallLogsAnOutcome() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let afterAwait = section(manager, from: "completion = await GhostTextModel.shared.complete(prompt)",
                                 to: "// Round 8 (#31)")
        XCTAssertTrue(afterAwait.contains("GhostTextLog.record("),
                      "the guard !Task.isCancelled return after .call logs nothing. Section was:\n\(afterAwait)")
    }

    /// Break c: the accept key's pass-through can fail (postGhostAcceptKey returns false on XPC error or when nothing
    /// was posted). The `else` is missing, so the lost Option+Tab is never logged.
    func testBreakR9_2bFailedAcceptPassThroughLogsALine() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let insert = section(manager, from: "private func insert(", to: "/// Re-reads the field")
        let tail = String(insert[(insert.range(of: "postGhostAcceptKey()")?.lowerBound ?? insert.endIndex)...])
        let elseBranch = tail.components(separatedBy: " else").dropFirst().joined()
        XCTAssertTrue(elseBranch.contains("GhostTextLog.record("),
                      "postGhostAcceptKey() == false (pass-through failed) has no else, so nothing is logged")
    }

    /// The reasons the three fixes log, so the new cases exist in the enum the log line is built from.
    func testBreakR9_ReasonsForCancelAndPassThroughExist() {
        XCTAssertNotNil(GhostTextEvent.Reason(rawValue: "cancelled"))
        XCTAssertNotNil(GhostTextEvent.Reason(rawValue: "passThroughFailed"))
    }
}
