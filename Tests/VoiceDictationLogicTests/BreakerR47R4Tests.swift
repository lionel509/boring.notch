import XCTest
@testable import VoiceDictationLogic

/// Breaker round 4 on PR #31 (comment 6462177508): an unreadable AX role, and a suggestion taken into another field.
final class BreakerR47R4Tests: XCTestCase {
    typealias G = GhostInsertGate

    private func read(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// B1: a role that cannot be read is secure at insert, so the app gate must refuse it at fetch too.
    func testB1UnreadableRoleIsRefusedByTheAppGate() throws {
        let json = #"{"bundleID":"com.google.Chrome","role":"","subrole":"","isSecure":false,"token":"t1","textBeforeCaret":"Name: ","caretLocation":6,"caretAtEnd":true}"#
        let snap = try JSONDecoder().decode(GhostTextSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: nil, subrole: nil), .secure)
        XCTAssertFalse(G.appAllows(token: snap.token, isSecure: snap.isSecure, role: snap.role, subrole: snap.subrole),
                       "app gate allows a field whose role is unreadable, which the helper refuses as secure")
    }

    /// B1, read side: the reader must not turn an unreadable role into a plain one.
    func testB1bReaderDoesNotDefaultAnUnreadableRoleToPlain() throws {
        let text = try read("BoringNotchXPCHelper/FocusedTextReader.swift")
        let needle = "string(focused, kAXRoleAttribute as String) ?? \"\""
        XCTAssertFalse(text.contains(needle), "reader defaults an unreadable role to an empty, plain role")
    }

    /// B2: a suggestion made for field X must not be written into field Y of the same app.
    func testB2SuggestionIsNotAcceptedInAnotherField() {
        var first = GhostTextSnapshot()
        first.bundleID = "com.google.Chrome"; first.caretLocation = 0; first.caretAtEnd = true
        first.textBeforeCaret = ""; first.fieldX = 100; first.fieldY = 200; first.token = "t1"
        let anchor = GhostTextLogic.Anchor(bundleID: first.bundleID, caretLocation: 0, contextTail: "")
        var other = first; other.fieldY = 600; other.token = "t2"
        XCTAssertFalse(GhostTextLogic.insertAllowed(anchor: anchor, now: other),
                       "a different field (other fieldY) was allowed to take the suggestion")
    }

    /// B2 fix: the anchor carries the fetch read's field frame. The same frame inserts, any other frame refuses.
    func testAnchorFieldFrameMustMatchExactly() {
        var fetched = GhostTextSnapshot()
        fetched.bundleID = "com.google.Chrome"; fetched.caretLocation = 0; fetched.caretAtEnd = true
        fetched.textBeforeCaret = ""; fetched.fieldX = 100; fetched.fieldY = 200
        fetched.fieldWidth = 400; fetched.fieldHeight = 30; fetched.token = "t1"
        let anchor = GhostTextLogic.Anchor(bundleID: fetched.bundleID, caretLocation: 0, contextTail: "",
                                           fieldX: 100, fieldY: 200, fieldWidth: 400, fieldHeight: 30)
        var same = fetched; same.token = "t2"
        XCTAssertTrue(GhostTextLogic.insertAllowed(anchor: anchor, now: same), "an unmoved field must still insert")
        var resized = same; resized.fieldWidth = 401
        XCTAssertFalse(GhostTextLogic.insertAllowed(anchor: anchor, now: resized), "a changed frame must refuse")
    }
}
