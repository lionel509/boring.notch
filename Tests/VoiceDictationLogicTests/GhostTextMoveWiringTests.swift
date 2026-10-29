import XCTest

/// Source pins for the #56 Shift tap and the #57 scroll monitor and drift check in the app target.
/// The SwiftPM target does not compile GhostTextManager.swift, so these read the source as text.
final class GhostTextMoveWiringTests: XCTestCase {
    private func sourceText(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testManagerWiresShiftTapScrollMonitorAndDriftCheck() throws {
        let text = try sourceText("boringNotch/Voice/Ghost/GhostTextManager.swift")
        for needle in [
            "CGEventType.flagsChanged.rawValue", "case .flagsChanged:", "handle(.shiftAccept)",
            "addGlobalMonitorForEvents(matching: .scrollWheel", "handle(.moved)", "NSEvent.removeMonitor",
            "if swallowedKey && GhostInsertGate.passThrough(", "GhostTextGeometry.drifted(", "dropOverlay(.caretMoved)",
        ] {
            XCTAssertTrue(text.contains(needle), needle)
        }
        XCTAssertGreaterThanOrEqual(count("shiftTaps.reset()", in: text), 5)
        XCTAssertGreaterThanOrEqual(count("driftTask?.cancel()", in: text), 3)
        XCTAssertFalse(text.contains("maskShift"), "the tap must not test modifiers itself")
    }

    func testFlagsChangedBranchNeverSwallows() throws {
        let text = try sourceText("boringNotch/Voice/Ghost/GhostTextManager.swift")
        guard let start = text.range(of: "case .flagsChanged:") else {
            return XCTFail("no flagsChanged case in the tap")
        }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "default:")?.lowerBound ?? rest.endIndex
        let branch = String(rest[..<end])
        XCTAssertTrue(branch.contains("return Unmanaged.passUnretained(event)"), "a Shift release must always pass through")
        XCTAssertFalse(branch.contains("return nil"), "a swallowed Shift release would leave Shift stuck down")
    }
}
