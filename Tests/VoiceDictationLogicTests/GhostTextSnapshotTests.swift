import XCTest
@testable import VoiceDictationLogic

final class GhostTextSnapshotTests: XCTestCase {
    func testDecodesFullFixture() throws {
        let json = """
        {"bundleID":"com.apple.Safari","appName":"Safari","windowTitle":"GitHub",
         "role":"AXTextArea","subrole":"","isSecure":false,"textBeforeCaret":"Hello wor",
         "caretX":100.0,"caretY":200.0,"caretWidth":2.0,"caretHeight":18.0}
        """
        let s = try XCTUnwrap(GhostTextSnapshot.decode(json))
        XCTAssertEqual(s.bundleID, "com.apple.Safari")
        XCTAssertEqual(s.textBeforeCaret, "Hello wor")
        XCTAssertEqual(s.caretX, 100.0)
        XCTAssertEqual(s.caretHeight, 18.0)
        XCTAssertTrue(s.hasCaret)
    }

    func testMissingTextAndCaretKeys() throws {
        let json = #"{"bundleID":"com.apple.TextEdit","appName":"TextEdit","windowTitle":"","role":"AXTextArea","subrole":"","isSecure":false}"#
        let s = try XCTUnwrap(GhostTextSnapshot.decode(json))
        XCTAssertNil(s.textBeforeCaret)
        XCTAssertFalse(s.hasCaret)
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(GhostTextSnapshot.decode("not json"))
        XCTAssertNil(GhostTextSnapshot.decode(""))
    }

    func testDecodesCaretAndFieldKeys() throws {
        let json = """
        {"bundleID":"com.apple.Safari","appName":"Safari","windowTitle":"GitHub",
         "role":"AXTextArea","subrole":"","isSecure":false,"textBeforeCaret":"Hello ",
         "caretLocation":6,"caretAtEnd":true,
         "caretX":120.0,"caretY":150.0,"caretWidth":0.0,"caretHeight":20.0,
         "fieldX":100.0,"fieldY":100.0,"fieldWidth":400.0,"fieldHeight":200.0}
        """
        let s = try XCTUnwrap(GhostTextSnapshot.decode(json))
        XCTAssertEqual(s.caretLocation, 6)
        XCTAssertTrue(s.caretAtEnd)
        XCTAssertEqual(s.caretRect, CGRect(x: 120, y: 150, width: 0, height: 20))
        XCTAssertEqual(s.fieldRect, CGRect(x: 100, y: 100, width: 400, height: 200))
    }

    func testCaretAndFieldRectsAreNilOnNaNOrZeroHeight() {
        var s = GhostTextSnapshot()
        s.caretX = 1; s.caretY = 2; s.caretWidth = 0; s.caretHeight = .nan
        XCTAssertNil(s.caretRect)
        s.caretHeight = 0
        XCTAssertNil(s.caretRect)
        s.fieldX = 0; s.fieldY = 0; s.fieldWidth = 10; s.fieldHeight = .nan
        XCTAssertNil(s.fieldRect)
        s.fieldHeight = 0
        XCTAssertNil(s.fieldRect)
    }
}
