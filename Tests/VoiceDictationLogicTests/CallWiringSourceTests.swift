import XCTest

/// Source-level checks for the call-detection wiring: the app files are not compiled by this package.
final class CallWiringSourceTests: XCTestCase {

    func testCallPromptIsAnAnnouncement() throws {
        let text = try appSource("boringNotch/BoringViewCoordinator.swift")
        let start = try XCTUnwrap(text.range(of: "var isAnnouncement: Bool"), "isAnnouncement moved; re-check this test")
        let end = try XCTUnwrap(text.range(of: "default: false", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".callPrompt"), ".callPrompt is not in isAnnouncement")
        XCTAssertTrue(text.contains("case callPrompt"), "SneakContentType has no .callPrompt case")
    }

    func testContentViewRendersCallPromptAsTheDictationRow() throws {
        let text = try appSource("boringNotch/ContentView.swift")
        XCTAssertTrue(text.contains("type == .callPrompt"), "ContentView does not render .callPrompt")
    }

    func testFnKeyMonitorRoutesAnswersToTheDetector() throws {
        let text = try appSource("boringNotch/Voice/FnKeyMonitor.swift")
        XCTAssertTrue(text.contains("output.answer"), "FnKeyMonitor does not read Output.answer")
        XCTAssertTrue(text.contains("CallDetector.shared.answer"), "FnKeyMonitor does not forward answers to CallDetector")
    }

    func testDictationManagerKeepsExactlyTwoListeners() throws {
        let text = try appSource("boringNotch/managers/DictationManager.swift")
        let count = text.components(separatedBy: "AudioObjectAddPropertyListenerBlock(").count - 1
        XCTAssertEqual(count, 2, "call detection must reuse the two existing mic listeners, not add more")
    }

    /// F3: a browser lookup must check its generation before it writes the per-pid caches.
    func testBrowserLookupChecksGenerationBeforeCaching() throws {
        let text = try appSource("boringNotch/Voice/CallDetector.swift")
        let lookup = try XCTUnwrap(text.range(of: "let titles = await"), "browser lookup moved; re-check this test")
        let insert = try XCTUnwrap(text.range(of: "self.resolvedPids.insert(client.pid)"), "cache write moved; re-check this test")
        let guardCheck = try XCTUnwrap(
            text.range(of: "guard gen == self.generation else { return }", range: lookup.upperBound..<text.endIndex),
            "no generation guard after the lookup")
        XCTAssertLessThan(guardCheck.upperBound, insert.lowerBound,
                          "a stale lookup can write resolvedPids before the generation guard")
    }

    /// Fix round: the prompt must still show when the fn tap is not active. Without the tap the keys cannot
    /// answer, but the prompt is still shown and times out like any other. It is never dropped silently.
    func testCallPromptShowsWhenTheFnTapIsNotActive() throws {
        let text = try appSource("boringNotch/Voice/CallDetector.swift")
        let start = try XCTUnwrap(text.range(of: "case .show(let call):"), "show effect moved; re-check this test")
        let end = try XCTUnwrap(text.range(of: "case .hide:", range: start.upperBound..<text.endIndex),
                                "hide effect moved; re-check this test")
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("guard"), "the show effect is still gated before it shows the prompt")
        XCTAssertFalse(body.contains("continue"), "the show effect still drops the prompt without showing it")
        XCTAssertTrue(body.contains("pending = call"), "the show effect does not set pending")
        XCTAssertTrue(body.contains("toggleSneakPeek"), "the show effect does not show the notch prompt")
    }

    func testCallDetectorHasNoTimerOrListener() throws {
        let text = try appSource("boringNotch/Voice/CallDetector.swift")
        XCTAssertFalse(text.contains("Timer"), "CallDetector must not poll with a Timer")
        XCTAssertFalse(text.contains("AudioObjectAddPropertyListener"), "CallDetector must not add its own listener")
    }

    private func appSource(_ relative: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/CallWiringSourceTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
