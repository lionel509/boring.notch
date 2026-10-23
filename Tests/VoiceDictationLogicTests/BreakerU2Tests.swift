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

    /// Break 5 (side effect, source pin): AXManualAccessibility is set to true on every dictated-into app and never
    /// set back. Chromium and Electron then keep their full accessibility tree on for the rest of the session. The
    /// ax-spike script restores both flags after its run; the helper restores neither.
    func testBreakManualAccessibilityIsTurnedBackOff() throws {
        let helper = try repoFile("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        XCTAssertTrue(helper.contains("AXManualAccessibility") && helper.contains("kCFBooleanFalse"),
                      "AXManualAccessibility is turned on and never restored to false")
    }

    /// F3 (review finding 3): the prepared-app fallback must trust the app's own AX frontmost flag, not
    /// NSWorkspace, which can be stale in an XPC service with no main run loop.
    func testFallbackFrontmostCheckReadsAXNotNSWorkspace() throws {
        let helper = try repoFile("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        XCTAssertTrue(helper.contains("kAXFrontmostAttribute"),
                      "the fallback does not read the prepared app's AXFrontmost")
        XCTAssertFalse(helper.contains("NSWorkspace.shared.frontmostApplication"),
                       "the fallback still trusts NSWorkspace.frontmostApplication, which can be stale")
    }
}
