import Foundation
import XCTest
@testable import VoiceDictationLogic

/// Breaker round 3 against PR #15 at head 5c0f707. Each test is one cash, privacy or overwrite path that the
/// round-2 fixes still get wrong. Red on 5c0f707 is the point of these tests. (The "so" planner cases that
/// passed are not kept; they are listed in the PR comment.)
final class BreakerR3Tests: XCTestCase {

    /// Path to the app sources from this test file: <root>/Tests/VoiceDictationLogicTests/<file>.
    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text from one marker up to another, used to read one function without parsing Swift.
    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    /// R3-2 (cash, privacy). A take that ends while STT is still running (the user types or clicks, or a new
    /// press supersedes it) discards the transcript, yet nothing cancels `sttTask`, and `cloudTranscript` never
    /// checks for cancellation. The second model is then sent for a take nobody is waiting on.
    func testR3AbandonedTakeCancelsItsSTTRequest() throws {
        let vdm = try appSource("boringNotch/Voice/VoiceDictationManager.swift")
        let insert = section(vdm, from: "private func insertAndRefine", to: "/// Tries the cloud transcription")
        let cloud = section(vdm, from: "private static func cloudTranscript", to: "/// On-device cleanup")
        XCTAssertFalse(insert.isEmpty, "insertAndRefine not found")
        let cancelsTask = insert.contains("sttTask.cancel()")
        let checksCancel = cloud.contains("Task.isCancelled") || cloud.contains("checkCancellation")
        XCTAssertTrue(cancelsTask || checksCancel,
                      "sttTask is never cancelled when the take ends, and cloudTranscript never checks cancellation: STT keeps billing after the take is gone")
    }

    /// R3-3 (overwrite user text). With the caret unreadable, the rewrite runs on key events and aborts only when
    /// a key event reaches it. `keyAbortLive` counts `AXIsProcessTrusted()` as a live key source. Accessibility
    /// trust does not grant the keyDown events the abort needs. The app itself treats them as separate: SettingsView
    /// asks for Input Monitoring "when Accessibility is granted but the tap still fails". With Accessibility granted,
    /// Input Monitoring missing, and fn dictation off (no tap), the abort is silent, so typed characters go unseen
    /// and the `.keys` swap counts from the user's new caret and deletes them.
    func testR3KeyAbortIsNotAssumedFromAccessibilityAlone() throws {
        let vdm = try appSource("boringNotch/Voice/VoiceDictationManager.swift")
        let gate = section(vdm, from: "let keyAbortLive =", to: "\n")
        XCTAssertFalse(gate.isEmpty, "keyAbortLive gate not found")
        XCTAssertFalse(
            gate.contains("|| AXIsProcessTrusted()"),
            "keyAbortLive is `\(gate.trimmingCharacters(in: .whitespaces))`: Accessibility alone does not deliver keyDown to the abort, so typing during a caret-less rewrite can be overwritten")
    }
}
