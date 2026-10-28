import XCTest
@testable import VoiceDictationLogic

/// #47 and #46 wiring, pinned against app source (the app target is not in the SwiftPM package).
final class GhostTextWiringTests: XCTestCase {

    /// Path to the app sources from this test file: <root>/Tests/VoiceDictationLogicTests/<file>.
    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text from one marker up to another, used to read one function without parsing Swift.
    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    private func count(_ text: String, _ needle: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testGhostTextSettingsHasItsOwnTabAndShortcutsLosesTheToggle() throws {
        let settings = try appSource("boringNotch/components/Settings/SettingsView.swift")
        let shortcuts = section(settings, from: "struct Shortcuts: View", to: "struct GhostTextSettings: View")
        XCTAssertFalse(shortcuts.isEmpty)
        XCTAssertFalse(shortcuts.contains(".ghostText"), "toggle must move out of Shortcuts")
        XCTAssertFalse(shortcuts.contains("GhostTextManager"), "ghost observer must move out of Shortcuts")
        XCTAssertTrue(settings.contains(#"NavigationLink(value: "GhostText")"#))
        XCTAssertTrue(settings.contains(#"Label("Ghost text""#))
        XCTAssertTrue(settings.contains(#"case "GhostText":"#))
        let tab = section(settings, from: "struct GhostTextSettings: View", to: "\nstruct ")
        XCTAssertTrue(tab.contains("Defaults.Toggle(key: .ghostText)"), tab)
    }

    func testManagerClassifiesEveryReadAndNeverUsesNoSnapshot() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertEqual(count(manager, "GhostSnapshotRead.classify("), 2)
        XCTAssertEqual(count(manager, "TimeoutRace.run("), 2)
        XCTAssertTrue(manager.contains("frontmostApplication"))
        XCTAssertFalse(manager.contains(".noSnapshot"))
        let fetch = section(manager, from: "private func fetch(gen", to: "GhostSnapshotRead.classify")
        XCTAssertTrue(fetch.contains("Task.isCancelled"), "fetch must drop a cancelled read before classifying it")
    }
}
