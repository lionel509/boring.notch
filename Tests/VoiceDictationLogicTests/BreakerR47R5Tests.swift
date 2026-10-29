import XCTest
@testable import VoiceDictationLogic

/// Breaker round 5 on PR #31 (comment 6462396218), the two fixes the round-5 review asked for:
/// an empty AX role is secure in the helper gate, and a frameless anchor never allows an insert.
final class BreakerR47R5Tests: XCTestCase {
    typealias G = GhostInsertGate

    func testR5_1EmptyRoleIsSecureInTheHelperGate() {
        XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: "", subrole: ""))
        XCTAssertTrue(G.isSecure(role: "", subrole: ""), "an empty role is treated as plain by isSecure")
        XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: "", subrole: ""), .secure)
    }

    func testR5_4FramelessAnchorCannotInsert() {
        let anchor = GhostTextLogic.Anchor(bundleID: "com.google.Chrome", caretLocation: 0, contextTail: "")
        var now = GhostTextSnapshot()
        now.bundleID = "com.google.Chrome"; now.caretLocation = 0; now.caretAtEnd = true
        now.textBeforeCaret = ""; now.token = "t2"
        XCTAssertFalse(GhostTextLogic.insertAllowed(anchor: anchor, now: now))
    }
}
