import XCTest
@testable import VoiceDictationLogic

private struct KeyDecisionLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33   // high bits: low bits of an LCG cycle too fast
    }
}

final class GhostTextKeyTests: XCTestCase {
    typealias L = GhostTextLogic

    private func event(
        _ keyCode: Int, _ chars: String, flags: UInt64 = 0,
        down: Bool = true, repeatKey: Bool = false, synthetic: Bool = false
    ) -> L.KeyEvent {
        L.KeyEvent(keyCode: keyCode, flags: flags, isKeyDown: down,
                   isAutorepeat: repeatKey, isSynthetic: synthetic, characters: chars)
    }

    /// The accept predicate from the round-7 amendment: Option+Tab only, real, non-repeat, visible.
    private func isAcceptPredicate(_ e: L.KeyEvent, visible: Bool) -> Bool {
        !e.isSynthetic && e.isKeyDown && e.keyCode == 48
            && e.flags & L.optionMask != 0
            && e.flags & (L.shiftMask | L.commandMask | L.controlMask) == 0
            && !e.isAutorepeat && visible
    }

    private func sourceText(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: Accept key (Option+Tab)

    func testPlainTabDismisses() {
        XCTAssertEqual(L.decide(event(48, "\t"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(48, "\t"), suggestionVisible: false), .dismiss)
    }

    func testOptionAloneIsIgnored() {
        XCTAssertEqual(L.decide(event(58, "", flags: L.optionMask), suggestionVisible: true), .ignore)
        XCTAssertEqual(L.decide(event(61, "", flags: L.optionMask), suggestionVisible: true), .ignore)
    }

    func testOptionWithAnyKeyCodeExceptTabNeverAccepts() {
        for code in 0...127 where code != 48 {
            let d = L.decide(event(code, "x", flags: L.optionMask), suggestionVisible: true)
            XCTAssertNotEqual(d, .accept, "keyCode \(code) with option accepted")
        }
    }

    func testOptionTabKeyUpIsNotAccept() {
        XCTAssertNotEqual(L.decide(event(48, "\t", flags: L.optionMask, down: false), suggestionVisible: true), .accept)
    }

    func testOptionTabAutorepeatIsNotAccept() {
        XCTAssertNotEqual(L.decide(event(48, "\t", flags: L.optionMask, repeatKey: true), suggestionVisible: true), .accept)
        XCTAssertEqual(L.decide(event(48, "\t", flags: L.optionMask, repeatKey: true), suggestionVisible: true), .dismiss)
    }

    func testOptionTabSyntheticIsIgnored() {
        XCTAssertEqual(L.decide(event(48, "\t", flags: L.optionMask, synthetic: true), suggestionVisible: true), .ignore)
    }

    func testOptionTabWithAnyOtherModifierIsNotAccept() {
        for extra in [L.shiftMask, L.commandMask, L.controlMask] {
            let d = L.decide(event(48, "\t", flags: L.optionMask | extra), suggestionVisible: true)
            XCTAssertNotEqual(d, .accept, "option+tab with modifier \(extra) accepted")
        }
    }

    /// Shift+Tab is Claude Code's mode toggle: with a suggestion visible it dismisses and passes through.
    func testShiftTabVisibleDismisses() {
        XCTAssertEqual(L.decide(event(48, "\t", flags: L.shiftMask), suggestionVisible: true), .dismiss)
    }

    func testOptionTabNotVisibleDismisses() {
        XCTAssertEqual(L.decide(event(48, "\t", flags: L.optionMask), suggestionVisible: false), .dismiss)
    }

    func testOptionTabVisibleAccepts() {
        XCTAssertEqual(L.decide(event(48, "\t", flags: L.optionMask), suggestionVisible: true), .accept)
    }

    // MARK: Typing

    func testPrintableKeysAreTyping() {
        XCTAssertEqual(L.decide(event(0, "a"), suggestionVisible: true), .typing)
        XCTAssertEqual(L.decide(event(0, "A", flags: L.shiftMask), suggestionVisible: true), .typing)
        XCTAssertEqual(L.decide(event(14, "é", flags: L.optionMask), suggestionVisible: true), .typing)
        XCTAssertEqual(L.decide(event(49, " "), suggestionVisible: true), .typing)
    }

    func testNavigationAndEditingKeysDismiss() {
        XCTAssertEqual(L.decide(event(123, "\u{F702}"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(124, "\u{F703}"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(125, "\u{F701}"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(126, "\u{F700}"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(36, "\r"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(76, "\u{3}"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(51, "\u{7F}"), suggestionVisible: true), .dismiss)
        XCTAssertEqual(L.decide(event(53, "\u{1B}"), suggestionVisible: true), .dismiss)
    }

    func testCommandVDismisses() {
        XCTAssertEqual(L.decide(event(9, "v", flags: L.commandMask), suggestionVisible: true), .dismiss)
    }

    /// 20,000 seeded random events: accept happens exactly when the predicate says so.
    func testAcceptIffPredicateOverRandomEvents() {
        var rng = KeyDecisionLCG(state: 0x29_0ACC)
        let masks = [L.shiftMask, L.controlMask, L.optionMask, L.commandMask]
        let pool = ["\t", "", "a", "\u{F702}", "\r"]
        var accepts = 0
        for _ in 0..<20_000 {
            var flags: UInt64 = 0
            for m in masks where rng.next() % 2 == 0 { flags |= m }
            let e = L.KeyEvent(
                keyCode: rng.next() % 4 == 0 ? 48 : Int(rng.next() % 128),
                flags: flags,
                isKeyDown: rng.next() % 4 != 0,
                isAutorepeat: rng.next() % 8 == 0,
                isSynthetic: rng.next() % 8 == 0,
                characters: pool[Int(rng.next() % UInt64(pool.count))]
            )
            for visible in [true, false] {
                let got = L.decide(e, suggestionVisible: visible) == .accept
                XCTAssertEqual(got, isAcceptPredicate(e, visible: visible), "\(e) visible=\(visible)")
                if got { accepts += 1 }
            }
        }
        // A green check must be able to go red: the accept branch has to be exercised.
        XCTAssertGreaterThan(accepts, 100)
    }

    // MARK: Source scans

    func testManagerHasNoShiftMaskAnymore() throws {
        let text = try sourceText("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertFalse(text.contains("maskShift"), "the tap must not test modifiers itself")
    }

    func testSettingsCopySaysShiftTwiceAndOptionTab() throws {
        let text = try sourceText("boringNotch/components/Settings/SettingsView.swift")
        XCTAssertTrue(text.contains("Tap Shift twice to type it"))
        XCTAssertTrue(text.contains("Option-Tab works too"))
        XCTAssertFalse(text.contains("Shift-Tab"))
    }
}
