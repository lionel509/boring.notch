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
        // Three reads: fetch, insert, and the #57 drift check (every read is classified).
        XCTAssertEqual(count(manager, "GhostSnapshotRead.classify("), 3)
        XCTAssertEqual(count(manager, "TimeoutRace.run("), 3)
        XCTAssertTrue(manager.contains("frontmostApplication"))
        XCTAssertFalse(manager.contains(".noSnapshot"))
        let fetch = section(manager, from: "private func fetch(gen", to: "GhostSnapshotRead.classify")
        XCTAssertTrue(fetch.contains("Task.isCancelled"), "fetch must drop a cancelled read before classifying it")
    }

    /// #47 finding 5: fetch and insert share the app-side gate, and an accept that wrote nothing passes Option+Tab back.
    func testFetchAndInsertShareTheGateAndInsertPassesThrough() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertEqual(count(manager, "GhostInsertGate.appAllows("), 2)
        // The result must gate the call (finding 3: `guard true || appAllows(` would still match the count above).
        XCTAssertEqual(count(manager, "guard GhostInsertGate.appAllows("), 2, "both sites must return on a refused gate")
        let fetch = section(manager, from: "private func fetch(gen", to: "private func dropFetch(")
        XCTAssertTrue(fetch.contains("GhostInsertGate.appAllows("))
        let attempt = section(manager, from: "private func attemptInsert(", to: "private let ghostTapCallback")
        let gate = attempt.range(of: "GhostInsertGate.appAllows(")?.lowerBound
        let allow = attempt.range(of: "GhostTextLogic.insertAllowed")?.lowerBound
        let call = attempt.range(of: "XPCHelperClient.shared.ghostInsert(token:")?.lowerBound
        XCTAssertNotNil(gate)
        XCTAssertNotNil(allow)
        XCTAssertNotNil(call)
        if let gate, let allow, let call {
            XCTAssertLessThan(gate, allow, "the token gate must come before the anchor check")
            XCTAssertLessThan(allow, call, "the anchor check must come before the write")
        }
        let insert = section(manager, from: "private func insert(_ text: String, keyApp", to: "private func attemptInsert(")
        XCTAssertTrue(insert.contains("GhostInsertGate.passThrough("))
        XCTAssertTrue(insert.contains("postGhostAcceptKey()"))
        let accept = section(manager, from: "case .accept(let text):", to: "case .swallow:")
        guard let front = accept.range(of: "frontmostApplication"), let task = accept.range(of: "Task {") else {
            return XCTFail("accept must read the key app before its Task")
        }
        XCTAssertLessThan(front.lowerBound, task.lowerBound)
        XCTAssertFalse(manager.contains("insertRefusal"))
    }
}
