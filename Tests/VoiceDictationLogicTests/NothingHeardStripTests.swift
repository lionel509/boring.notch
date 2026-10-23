import Foundation
import XCTest
@testable import VoiceDictationLogic

/// r5 fix2, bug 2: the failure ("Nothing heard") strip must not overlap its bars with its text, and it must keep
/// the listening strip's width (the +60 pt footprint) instead of growing by a message cell.
final class NothingHeardStripTests: XCTestCase {
    /// The listening footprint is `extraWidth(showsMessage: false)`: an icon cell, a bars cell, 20 pt.
    /// A failure's right-hand cell is the bars cell's slot plus the 20 pt, so the total is the same.
    func testFailureCellPlusIconCellIsTheListeningFootprint() {
        for side: CGFloat in [12, 20, 24] {
            XCTAssertEqual(
                DictationStrip.extraWidth(side: side, showsMessage: false),
                side + DictationStrip.failureCellWidth(side: side),
                accuracy: 0.001,
                "side \(side): the failure strip is not the listening width")
        }
    }

    /// Source: the error branch of the activity draws no bars and the message is not wrapped in the bars cell.
    func testErrorStateHidesTheBars() throws {
        let text = try appSource("boringNotch/Voice/VoiceDictationLiveActivity.swift")
        let start = try XCTUnwrap(text.range(of: "case .failed(let message):"), "the failed branch moved; re-check this test")
        let end = try XCTUnwrap(text.range(of: "    }\n\n    /// The strip's bars cell", range: start.upperBound..<text.endIndex))
        let branch = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(branch.contains("bars("), "the failure branch still draws the level bars next to the text")
        XCTAssertTrue(branch.contains("DictationStrip.failureCellWidth"), "the failure text is not sized to the shared cell width")
    }

    /// Source: the chin and the activity both take the width from the same constant, so the failure cell cannot drift.
    func testErrorWidthIsSharedWithTheListeningState() throws {
        let chin = try appSource("boringNotch/ContentView.swift")
        XCTAssertTrue(chin.contains("DictationStrip.extraWidth"), "the chin no longer takes its width from DictationStrip")
        let activity = try appSource("boringNotch/Voice/VoiceDictationLiveActivity.swift")
        XCTAssertTrue(
            activity.contains("DictationStrip.failureCellWidth(side: side)"),
            "the activity sizes the failure cell from something other than the shared DictationStrip width")
        let failureRule = try appSource("boringNotch/Voice/Logic/DictationStrip.swift")
        XCTAssertTrue(failureRule.contains("static func failureCellWidth(side: CGFloat) -> CGFloat"), "the shared width is missing")
        XCTAssertFalse(
            chin.contains("case .failed: return true"),
            "the chin still reserves a message cell for failures, so the failure strip is wider than the listening strip")
    }

    private func appSource(_ relative: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/NothingHeardStripTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
