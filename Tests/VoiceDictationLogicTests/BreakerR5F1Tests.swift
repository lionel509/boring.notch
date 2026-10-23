import Foundation
import XCTest
@testable import VoiceDictationLogic

/// Breaker round 5, fix round F1 to F5 (PR #15, head c6b18bf). Tests named `testBreak...` are expected to fail on
/// c6b18bf; each one states the invariant the fix claims to hold.
final class BreakerR5F1Tests: XCTestCase {
    private func repoFile(_ rel: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/BreakerR5F1Tests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The text from one marker up to the next, without parsing Swift.
    private func body(_ text: String, from start: String, to end: String) -> String? {
        guard let a = text.range(of: start) else { return nil }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    /// Break 1 (F2, restore on every exit path). discard() ends a take without ending the helper's tracking. A quick
    /// fn tap or a fn modifier still calls prepareFocus at press (the press Task runs before the discard), which turns
    /// AXManualAccessibility on for the frontmost Electron or Chromium app. discard() never sends endTracking, so the
    /// flag stays on until some later take happens to run. Other exits (cancel, fail, insert) do send it.
    func testBreakDiscardEndsTrackingSoTheFlagIsRestored() throws {
        let vdm = try repoFile("boringNotch/Voice/VoiceDictationManager.swift")
        let discard = try XCTUnwrap(body(vdm, from: "private func discard()", to: "/// Logs the take's report"),
                                    "discard() not found")
        XCTAssertTrue(discard.contains("endTracking"),
                      "discard() never calls endTracking, so AXManualAccessibility stays on after a quick fn tap")
    }

    /// Break 2 (F1, secure check on every helper path). F1 added the subrole check to focusedTextValue and beginTracking
    /// only. Every other helper call that reads or writes the tracked element goes through trackedFocus(): caretLocation,
    /// stringForRange, axReplace and typeSwap. trackedFocus() does not refuse a secure field, so those calls still work on
    /// a password field. Only the Swift gate stands in front of them.
    func testBreakTrackedFocusRefusesSecureFields() throws {
        let helper = try repoFile("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        let tracked = try XCTUnwrap(body(helper, from: "private func trackedFocus()", to: "/// 4 when nothing is tracked"),
                                    "trackedFocus() not found")
        XCTAssertTrue(tracked.contains("AXSecureTextField") || tracked.contains("kAXSubroleAttribute"),
                      "trackedFocus() returns secure fields too: stringForRange, axReplace and typeSwap work on a password field")
    }

    /// Break 3 (F1, fail-open). beginTracking reports secure=false when the role and subrole attributes cannot be read
    /// (an empty role, for example while a Chromium tree is still building after prepareFocus). RewriteMechanism.choose
    /// then returns a rewrite mechanism for any non-secure field, so the gate runs. An unreadable field is not proven
    /// non-secure and must not run.
    func testBreakUnreadableRoleIsNotRunAsNonSecure() {
        let f = FocusedField(pid: 42, bundle: "com.google.Chrome", role: "",
                             secure: false, caret: 5, rangeSettable: true, textSettable: true)
        let d = RewriteGate.decide(field: f, cloudOn: true, hasKey: true, cleanupOn: true, keyAbortLive: true)
        if case .run = d {
            XCTFail("a field with an unreadable role and subrole ran a rewrite; the gate fails open: \(d)")
        }
    }
}
