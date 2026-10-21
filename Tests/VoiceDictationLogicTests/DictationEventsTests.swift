import XCTest
@testable import VoiceDictationLogic

/// U4 / I3: every synthesized event carries one tag, and the app's taps and monitors ignore it, so the
/// rewrite never reads its own keystrokes as the user touching the text.
final class DictationEventsTests: XCTestCase {
    func testTagIsTheDocumentedLiteral() {
        XCTAssertEqual(DictationEvents.tag, 0x424E4443)
    }

    /// The helper target compiles its own copy (the helper cannot import the app's Logic folder).
    func testHelperAndAppCopiesOfDictationEventsAreIdentical() throws {
        let app = try source("boringNotch/Voice/Logic/DictationEvents.swift")
        let helper = try source("BoringNotchXPCHelper/DictationEvents.swift")
        XCTAssertEqual(app, helper)
    }

    func testXPCProtocolCopiesAreIdentical() throws {
        let app = try source("boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift")
        let helper = try source("BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift")
        XCTAssertEqual(app, helper)
        XCTAssertTrue(app.contains("openRouterKey"))
        XCTAssertTrue(app.contains("axSelectThenType"))
    }

    /// FnKeyMonitor drops tagged events before its fn logic and watches the mouse for aborts.
    func testFnKeyMonitorIgnoresTaggedEventsAndWatchesMouse() throws {
        let text = try source("boringNotch/Voice/FnKeyMonitor.swift")
        XCTAssertTrue(text.contains("DictationEvents.tag"))
        XCTAssertTrue(text.contains(".leftMouseDown"))
        XCTAssertTrue(text.contains(".scrollWheel"))
        XCTAssertTrue(text.contains("userInput"))
    }

    private func source(_ path: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/DictationEventsTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
