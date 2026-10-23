import Foundation
import XCTest

/// r5 notice, follow-up: a dictation notice must look exactly like the song-change row under the closed
/// notch (`music.note` + grey text, one row down), not like the system alert. These are source-reading checks
/// because the view code is in the app target, which this package does not build.
final class DictationRowSourceTests: XCTestCase {
    private func contentView() throws -> String {
        try appSource("boringNotch/ContentView.swift")
    }

    /// The `.dictation` row sits beside the `.music` row in the sneak-peek chain, and shares its shape.
    func testDictationHasItsOwnRowBesideTheMusicRow() throws {
        let text = try contentView()
        let music = try XCTUnwrap(text.range(of: "else if coordinator.sneakPeek.type == .music {"), "music row moved; re-check this test")
        let dictation = try XCTUnwrap(text.range(of: "else if coordinator.sneakPeek.type == .dictation {"), "ContentView has no .dictation row")
        XCTAssertLessThan(music.lowerBound, dictation.lowerBound, "the .dictation row is not beside the .music row")
        XCTAssertLessThan(dictation.lowerBound.utf16Offset(in: text) - music.lowerBound.utf16Offset(in: text), 1500,
                          ".dictation row is not directly after the .music row")
    }

    func testDictationRowMatchesTheMusicRowShape() throws {
        let text = try contentView()
        let start = try XCTUnwrap(text.range(of: "else if coordinator.sneakPeek.type == .dictation {"), "ContentView has no .dictation row")
        let body = String(text[start.lowerBound...].prefix(1000))
        XCTAssertTrue(body.contains("Image(systemName: coordinator.sneakPeek.icon)"), "the dictation row has no icon from the notice")
        XCTAssertTrue(body.contains("Text("), "the dictation row is not plain Text")
        XCTAssertTrue(body.contains("coordinator.sneakPeek.label"), "the dictation row does not read the notice label")
        XCTAssertTrue(body.contains("\" · \""), "the dictation row does not join the detail with a middle dot")
        XCTAssertTrue(body.contains(".lineLimit(1)"), "the dictation row can wrap")
        XCTAssertTrue(body.contains(".foregroundStyle(.gray)"), "the dictation row is not grey like the music row")
        XCTAssertTrue(body.contains(".padding(.bottom, 10)"), "the dictation row does not sit the same distance above the bottom")
        XCTAssertFalse(body.contains("MarqueeText"), "the dictation row scrolls; labels are short and should not")
        XCTAssertFalse(body.contains("sneakPeekStyles"), "the dictation row is gated on sneakPeekStyles; it must always show")
    }

    /// The row shows whenever the notch is closed and not hidden, like the music row's standard branch.
    func testDictationRowIsShownWhenClosedAndNotHidden() throws {
        let text = try contentView()
        let start = try XCTUnwrap(text.range(of: "else if coordinator.sneakPeek.type == .dictation {"), "ContentView has no .dictation row")
        let body = String(text[start.lowerBound...].prefix(400))
        XCTAssertTrue(body.contains("vm.notchState == .closed && !vm.hideOnClosed"), "the dictation row is not gated on closed and not hidden")
    }

    /// The content chain used to hand `.dictation` to InlineHUD, because it is an announcement. The row alone draws it now.
    func testInlineHUDDoesNotTakeDictation() throws {
        let text = try contentView()
        let inline = try XCTUnwrap(text.range(of: "InlineHUD(type: $coordinator.sneakPeek.type"), "InlineHUD call moved")
        let condition = String(text[..<inline.lowerBound].suffix(400))
        XCTAssertTrue(condition.contains("coordinator.sneakPeek.type != .dictation"), "InlineHUD still renders the dictation notice")
    }

    /// The old system-alert styling must not carry dictation any more.
    func testDictationIsNotInTheSystemAlertRendering() throws {
        let text = try appSource("boringNotch/components/Live activities/InlineHUD.swift")
        XCTAssertFalse(text.contains("case .systemAlert, .dictation"), "InlineHUD still renders dictation like a system alert")
        XCTAssertTrue(text.contains("case .systemAlert:"), "the system alert rendering went missing")
    }

    /// The closed notch sizes itself to a peek. For `.dictation` that is the same as the standard music peek:
    /// it grows down by the row, and it does so whatever `sneakPeekStyles` says.
    func testDictationTakesTheSameIntrinsicSizeAsTheStandardMusicPeek() throws {
        let text = try contentView()
        let start = try XCTUnwrap(text.range(of: "private var peekTakesIntrinsicWidth: Bool {"), "peekTakesIntrinsicWidth moved")
        let end = try XCTUnwrap(text.range(of: "func NotchLayout", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("coordinator.sneakPeek.type == .dictation"), "peekTakesIntrinsicWidth does not mention .dictation")
        XCTAssertTrue(body.contains("!vm.hideOnClosed"), "the dictation peek is not gated on hideOnClosed like the music peek")
        XCTAssertFalse(body.contains("Defaults[.sneakPeekStyles] == .inline"), "the sizing reads the inline style")
        XCTAssertTrue(text.contains(".fixedSize(horizontal: peekTakesIntrinsicWidth, vertical: peekTakesIntrinsicWidth)"),
                      "the peek no longer grows with its content")
    }

    private func appSource(_ relative: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/DictationRowTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
