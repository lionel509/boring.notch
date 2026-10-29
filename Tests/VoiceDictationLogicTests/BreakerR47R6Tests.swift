import XCTest
@testable import VoiceDictationLogic

/// Breaker round 6 on PR #31 (comment 6462518801), break 1: a whitespace-only AX role must count as
/// empty, so the gate fails closed on it in isSecure, appAllows and the helper refusal.
final class BreakerR47R6Tests: XCTestCase {
    typealias G = GhostInsertGate

    func testR6_1WhitespaceOnlyRoleIsSecure() {
        for role in ["   ", "\t", "\n", " \u{00A0} "] {
            XCTAssertTrue(G.isSecure(role: role, subrole: ""), "whitespace role \(role.debugDescription) read as plain")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: role, subrole: ""),
                           "app gate allows whitespace role \(role.debugDescription)")
            XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: role, subrole: ""), .secure,
                           "helper gate writes into whitespace role \(role.debugDescription)")
        }
    }

    func testR6_1WireWhitespaceRoleCannotFetchOrInsert() {
        let raw = #"{"bundleID":"com.google.Chrome","appName":"Chrome","role":"   ","isSecure":false,"textBeforeCaret":"hello wor","caretLocation":9,"caretAtEnd":true,"caretX":10,"caretY":10,"caretWidth":1,"caretHeight":14,"fieldX":0,"fieldY":0,"fieldWidth":400,"fieldHeight":30,"token":"t1"}"#
        guard case .snapshot(let snap, _, _) = GhostSnapshotRead.classify(.some(raw), frontmostBundleID: "com.google.Chrome") else {
            XCTFail("read should classify as a snapshot: \(raw)")
            return
        }
        XCTAssertFalse(G.appAllows(token: snap.token, isSecure: snap.isSecure, role: snap.role, subrole: snap.subrole),
                       "whitespace role from the wire is allowed to fetch and insert")
    }
}
