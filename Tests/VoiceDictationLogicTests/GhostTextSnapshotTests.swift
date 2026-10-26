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
}
