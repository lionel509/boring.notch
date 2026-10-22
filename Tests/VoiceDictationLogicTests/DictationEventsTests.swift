import XCTest
@testable import VoiceDictationLogic

/// U4 / I3: every synthesized event carries one tag, and the app's taps and monitors ignore it, so the
/// rewrite never reads its own keystrokes as the user touching the text.
final class DictationEventsTests: XCTestCase {
    func testTagIsTheDocumentedLiteral() {
        XCTAssertEqual(DictationEvents.tag, 0x424E4443)
    }

    func testIsSynthesizedMatchesOnlyTheTag() {
        XCTAssertTrue(DictationEvents.isSynthesized(DictationEvents.tag))
        XCTAssertFalse(DictationEvents.isSynthesized(0))
    }

    /// The helper must tag every CGEvent it builds: one `tag(` call per construction site at least.
    func testHelperTagsEveryConstructedEvent() throws {
        let helper = try source("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        let constructions = helper.components(separatedBy: "CGEvent(").count - 1
        let calls = (helper.components(separatedBy: "tag(").count - 1) - (helper.components(separatedBy: "func tag(").count - 1)
        XCTAssertGreaterThanOrEqual(calls, constructions, "a synthesized CGEvent is sent without the tag")
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
        XCTAssertTrue(text.contains("if DictationEvents.isSynthesized(event.getIntegerValueField(.eventSourceUserData)) { return Unmanaged.passUnretained(event) }"))
        XCTAssertTrue(text.contains("userInput?(type)"))
        XCTAssertTrue(text.contains(".leftMouseDown"))
        XCTAssertTrue(text.contains(".scrollWheel"))
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
