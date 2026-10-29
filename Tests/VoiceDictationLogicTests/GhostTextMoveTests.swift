import XCTest
@testable import VoiceDictationLogic

private struct MoveLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33   // high bits: low bits of an LCG cycle too fast
    }
}

/// #56 (Shift accept) and #57 (scroll moves the suggestion away, and the drift check).
final class GhostTextMoveTests: XCTestCase {
    typealias L = GhostTextLogic

    /// Drives the machine to a visible suggestion "hello" and returns its gen.
    private func showing(_ m: inout L.Machine) -> Int {
        _ = m.handle(.key(.typing))
        let g = m.gen
        _ = m.handle(.pauseFired(gen: g))
        _ = m.handle(.suggestion("hello", gen: g))
        return g
    }

    private func isAccept(_ e: L.Effect) -> Bool {
        if case .accept = e { return true }
        return false
    }

    private func isAcceptPredicate(_ e: L.KeyEvent, visible: Bool) -> Bool {
        !e.isSynthetic && e.isKeyDown && e.keyCode == 48
            && e.flags & L.optionMask != 0
            && e.flags & (L.shiftMask | L.commandMask | L.controlMask) == 0
            && !e.isAutorepeat && visible
    }

    // MARK: Shift accept (#56)

    func testShiftAcceptWhileShowingInsertsWithoutSwallowing() {
        var m = L.Machine()
        _ = showing(&m)
        let effects = m.handle(.shiftAccept)
        XCTAssertEqual(effects, [.hide(.accepted), .accept("hello")])
        XCTAssertFalse(effects.contains(.swallow))
        XCTAssertFalse(m.isShowing)
    }

    func testShiftAcceptWithNothingShowingDoesNothing() {
        var m = L.Machine()
        XCTAssertEqual(m.handle(.shiftAccept), [])
        XCTAssertEqual(m.state, .idle)
        _ = m.handle(.key(.typing))
        let waiting = m.state
        XCTAssertEqual(m.handle(.shiftAccept), [])
        XCTAssertEqual(m.state, waiting)
        _ = m.handle(.pauseFired(gen: m.gen))
        let requesting = m.state
        XCTAssertEqual(m.handle(.shiftAccept), [])
        XCTAssertEqual(m.state, requesting)
    }

    // MARK: Scroll moves (#57)

    func testMovedWhenIdleDoesNothing() {
        var m = L.Machine()
        XCTAssertEqual(m.handle(.moved), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testMovedWhileShowingHidesAndSchedulesAFreshFetch() {
        var m = L.Machine()
        let g = showing(&m)
        XCTAssertEqual(m.handle(.moved), [.hide(.moved), .cancelFetch, .scheduleTimer(gen: g + 1)])
        XCTAssertEqual(m.state, .waiting(gen: g + 1))
        XCTAssertFalse(m.isShowing)
    }

    func testMovedWhileWaitingOrRequestingDoesNotHideAndDropsStaleSuggestion() {
        var m = L.Machine()
        _ = m.handle(.key(.typing))
        XCTAssertEqual(m.handle(.moved), [.cancelFetch, .scheduleTimer(gen: 2)])
        _ = m.handle(.pauseFired(gen: 2))
        let g = m.gen
        XCTAssertEqual(m.handle(.moved), [.cancelFetch, .scheduleTimer(gen: g + 1)])
        XCTAssertEqual(m.handle(.suggestion("x", gen: g)), [])
        XCTAssertFalse(m.isShowing)
    }

    func testMovedThenFreshPauseShowsAgainAtTheNewAnchor() {
        var m = L.Machine()
        _ = showing(&m)
        _ = m.handle(.moved)
        let g = m.gen
        XCTAssertEqual(m.handle(.pauseFired(gen: g)), [.fetch(gen: g)])
        XCTAssertEqual(m.handle(.suggestion("x", gen: g)), [.show("x")])
        XCTAssertTrue(m.isShowing)
    }

    /// 5,000 seeded random sequences over every input, including moves and Shift accepts.
    func testInvariantWithMovesAndShiftAccepts() {
        var rng = MoveLCG(state: 0x57_3A)
        let pool = ["\t", "", "a", "\u{F702}", "\r"]
        let masks = [L.shiftMask, L.controlMask, L.optionMask, L.commandMask]
        var keyAccepts = 0
        var shiftAccepts = 0
        for _ in 0..<5_000 {
            var m = L.Machine()
            var fetchesSinceReset = 0
            for _ in 0..<40 {
                let before = m.isShowing
                var event: L.KeyEvent? = nil
                let input: L.Input
                let roll = rng.next() % 11
                let genPick = rng.next() % 2 == 0 ? m.gen : Int(rng.next() % UInt64(m.gen + 2))
                switch roll {
                case 0, 1, 2:
                    var flags: UInt64 = 0
                    for mask in masks where rng.next() % 3 == 0 { flags |= mask }
                    let e = L.KeyEvent(
                        keyCode: rng.next() % 4 == 0 ? 48 : Int(rng.next() % 128), flags: flags,
                        isKeyDown: rng.next() % 4 != 0, isAutorepeat: rng.next() % 8 == 0,
                        isSynthetic: rng.next() % 8 == 0,
                        characters: pool[Int(rng.next() % UInt64(pool.count))])
                    event = e
                    input = .key(L.decide(e, suggestionVisible: before))
                case 3: input = .pauseFired(gen: genPick)
                case 4: input = .suggestion(rng.next() % 2 == 0 ? "s" : nil, gen: genPick)
                case 5: input = .snapshotFailed(gen: genPick)
                case 6: input = .focusChanged
                case 7: input = .tapReset
                case 8: input = .moved
                case 9: input = .shiftAccept
                default: input = .stop
                }
                let effects = m.handle(input)
                let typingOrMoved = input == .moved || input == .key(.typing)
                if typingOrMoved { fetchesSinceReset = 0 }
                fetchesSinceReset += effects.filter { if case .fetch = $0 { return true } else { return false } }.count
                XCTAssertLessThanOrEqual(fetchesSinceReset, 1, "two fetches without typing or a move in between")

                if input == .moved { XCTAssertFalse(m.isShowing, "still showing right after a move") }

                if effects.contains(where: isAccept) {
                    XCTAssertTrue(before, "accept while not showing")
                    if input == .shiftAccept {
                        shiftAccepts += 1
                    } else if let e = event, input == .key(.accept) {
                        keyAccepts += 1
                        XCTAssertTrue(isAcceptPredicate(e, visible: before), "accept from \(e)")
                    } else {
                        XCTFail("accept from \(input)")
                    }
                }
                if effects.contains(.swallow) {
                    XCTAssertTrue(input == .key(.accept), "swallow from \(input)")
                }
            }
        }
        // A green check must be able to go red: both accept sources have to be exercised.
        XCTAssertGreaterThan(keyAccepts, 0)
        XCTAssertGreaterThan(shiftAccepts, 0)
    }

    // MARK: Drift check (#57)

    func testDriftedIgnoresSubPointJitterAndCatchesRealMoves() {
        let caret = CGRect(x: 100, y: 200, width: 2, height: 16)
        let field = CGRect(x: 50, y: 150, width: 400, height: 300)
        XCTAssertFalse(GhostTextGeometry.drifted(drawnCaret: caret, drawnField: field, nowCaret: caret, nowField: field))
        let jitter = CGRect(x: 101.5, y: 200.5, width: 2, height: 16)
        XCTAssertFalse(GhostTextGeometry.drifted(drawnCaret: caret, drawnField: field, nowCaret: jitter, nowField: field))
        XCTAssertTrue(GhostTextGeometry.drifted(drawnCaret: caret, drawnField: field,
                                                nowCaret: caret.offsetBy(dx: 0, dy: 3), nowField: field))
        XCTAssertTrue(GhostTextGeometry.drifted(drawnCaret: caret, drawnField: field,
                                                nowCaret: caret, nowField: field.offsetBy(dx: 3, dy: 0)))
        XCTAssertTrue(GhostTextGeometry.drifted(drawnCaret: caret, drawnField: field,
                                                nowCaret: caret, nowField: CGRect(x: 50, y: 150, width: 403, height: 300)))
        XCTAssertTrue(GhostTextGeometry.drifted(drawnCaret: caret, drawnField: field, nowCaret: nil, nowField: field))
        XCTAssertTrue(GhostTextGeometry.drifted(drawnCaret: caret, drawnField: field, nowCaret: caret, nowField: nil))
    }
}
