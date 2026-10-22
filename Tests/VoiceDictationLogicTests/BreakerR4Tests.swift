import Foundation
import XCTest
@testable import VoiceDictationLogic

/// Breaker round 4 against PR #15 at head ab24e9f. Attacks the round-3 fixes. Red on ab24e9f is the point.
final class BreakerR4Tests: XCTestCase {

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

    /// R4-1 (cash). A take the user ends by typing or clicking while the cloud STT is still pending. The rewrite
    /// run returns at once, but `insertAndRefine` then waits on `finalTask` (Apple's finalize, up to about 3 s in
    /// `SpeechAnalyzerSession.finish`) before it returns. The `defer { sttTask.cancel() }` only fires when the
    /// function returns, so the abandoned STT request keeps running through that wait. If the first model passes
    /// its 2.5 s cap in that window, `cloudTranscript` sends the second model for a take nobody uses.
    /// Fix: cancel `sttTask` right after `running.run` returns, before awaiting `finalTask`.
    func testR4AbandonedRewriteCancelsSTTBeforeWaitingForAppleFinal() throws {
        let vdm = try appSource("boringNotch/Voice/VoiceDictationManager.swift")
        let afterRun = section(vdm, from: "await running.run(", to: "closeRewrite(running)")
        XCTAssertFalse(afterRun.isEmpty, "the post-rewrite section of insertAndRefine was not found")
        guard let finalWait = afterRun.range(of: "await finalTask.value") else {
            return XCTFail("the Apple final wait moved; re-check the ordering this test pins")
        }
        let beforeWait = afterRun[..<finalWait.lowerBound]
        XCTAssertTrue(
            beforeWait.contains("sttTask.cancel()"),
            "sttTask is cancelled only when insertAndRefine returns, after `await finalTask.value` (up to ~3 s). A take the user ended mid-rewrite keeps its cloud STT request alive through that wait, so the second STT model can be billed for an abandoned take.")
    }
}
