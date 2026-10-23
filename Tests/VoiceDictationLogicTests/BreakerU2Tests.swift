import XCTest
@testable import VoiceDictationLogic

/// Breaker round 5, unit U2 (PR #15, head 90f917a): attacks on the rewrite gate and the AX focus prep.
/// Tests named `testBreak...` fail on the PR head; each one states the invariant it pins.
final class BreakerU2Tests: XCTestCase {
    private func repoFile(_ rel: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/BreakerU2Tests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Break 1 (gate, defense in depth): the gate trusts the `secure` boolean only. A field whose reported role is
    /// AXSecureTextField but whose flag reads false must still be skipped. The helper sets both from the same role
    /// today, so this is not reachable from the live helper; it is the gate's only guard if that ever changes.
    func testBreakRoleSecureTextFieldWithFalseFlagIsSkipped() {
        let f = FocusedField(pid: 42, bundle: "com.apple.TextEdit", role: "AXSecureTextField",
                             secure: false, caret: 5, rangeSettable: true, textSettable: true)
        let d = RewriteGate.decide(field: f, cloudOn: true, hasKey: true, cleanupOn: true, keyAbortLive: true)
        XCTAssertEqual(d, .skip(.secureField), "a secure-role field ran a rewrite: \(d)")
    }

    /// Break 2 (helper, source pin): password fields in some apps expose role AXTextField with subrole
    /// AXSecureTextField. beginTracking only compares the role, so such a field reports secure=false and the gate
    /// runs. Unverified on device (no Chrome or Safari password field was tested here).
    func testBreakHelperChecksSecureSubrole() throws {
        let helper = try repoFile("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        XCTAssertTrue(helper.contains("kAXSubroleAttribute"),
                      "beginTracking decides secure from the role only; a password subrole is never read")
    }

    /// Break 3 (manager, source pin): the four insert() failure returns end the take with no reason. The
    /// "Helper slow, paste may still land" branch can leave the text in the field while the report says
    /// failed, rewrite=none and skip=none, and the gate's skip reason is never written for it.
    func testBreakInsertFailureRecordsAReason() throws {
        let lines = try repoFile("boringNotch/Voice/VoiceDictationManager.swift").components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("guard await insert(text) else") }) else {
            return XCTFail("call site not found")
        }
        let window = lines[i...min(i + 3, lines.count - 1)].joined(separator: "\n")
        XCTAssertTrue(window.contains("cleanupSkip"),
                      "insert failure returns with no cleanupSkip; the take ends rewrite=none skip=none")
    }

    /// Break 4 (stall, source pin): prepareFocus makes synchronous AX calls to the frontmost app. A hung app blocks
    /// each one for the default AX messaging timeout (6 s), and the helper's XPC queue waits behind them, so the
    /// release-time beginTracking and the paste wait too. No messaging timeout is set anywhere in the helper.
    func testBreakPrepareFocusBoundsAXWaits() throws {
        let helper = try repoFile("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        XCTAssertTrue(helper.contains("AXUIElementSetMessagingTimeout"),
                      "prepareFocus can block the helper queue for 6 s per AX call on a hung app")
    }

    /// Break 5 (side effect, source pin): AXManualAccessibility is set to true on every dictated-into app and never
    /// set back. Chromium and Electron then keep their full accessibility tree on for the rest of the session. The
    /// ax-spike script restores both flags after its run; the helper restores neither.
    func testBreakManualAccessibilityIsTurnedBackOff() throws {
        let helper = try repoFile("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        XCTAssertTrue(helper.contains("AXManualAccessibility") && helper.contains("kCFBooleanFalse"),
                      "AXManualAccessibility is turned on and never restored to false")
    }
}
