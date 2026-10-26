import XCTest
@testable import VoiceDictationLogic

private struct MachineLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class GhostTextLogicTests: XCTestCase {
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

    func testTypingSchedulesTimerAndPauseFetchesOnce() {
        var m = L.Machine()
        XCTAssertEqual(m.handle(.key(.typing)), [.cancelFetch, .scheduleTimer(gen: 1)])
        XCTAssertEqual(m.handle(.pauseFired(gen: 1)), [.fetch(gen: 1)])
        XCTAssertEqual(m.handle(.pauseFired(gen: 1)), [])
        XCTAssertEqual(m.handle(.suggestion("hello", gen: 1)), [.show("hello")])
        XCTAssertTrue(m.isShowing)
    }

    func testStaleGenTimerIsDropped() {
        var m = L.Machine()
        _ = m.handle(.key(.typing))
        _ = m.handle(.key(.typing))
        XCTAssertEqual(m.handle(.pauseFired(gen: 1)), [])
        XCTAssertEqual(m.handle(.pauseFired(gen: 2)), [.fetch(gen: 2)])
    }

    func testAfterDismissPauseFiredIsDroppedUntilNewTyping() {
        var m = L.Machine()
        _ = m.handle(.key(.typing))
        let g = m.gen
        _ = m.handle(.key(.dismiss))
        XCTAssertEqual(m.handle(.pauseFired(gen: g)), [])
        XCTAssertEqual(m.handle(.pauseFired(gen: m.gen)), [])
        XCTAssertEqual(m.handle(.pauseFired(gen: m.gen + 1)), [])
        _ = m.handle(.key(.typing))
        XCTAssertEqual(m.handle(.pauseFired(gen: m.gen)), [.fetch(gen: m.gen)])
    }

    func testTypingDuringRequestCancelsFetchAndDropsLateSuggestion() {
        var m = L.Machine()
        _ = m.handle(.key(.typing))
        let old = m.gen
        _ = m.handle(.pauseFired(gen: old))
        XCTAssertTrue(m.handle(.key(.typing)).contains(.cancelFetch))
        XCTAssertEqual(m.handle(.suggestion("late", gen: old)), [])
        XCTAssertFalse(m.isShowing)
    }

    func testSuggestionAfterFocusChangeIsDropped() {
        var m = L.Machine()
        _ = m.handle(.key(.typing))
        let g = m.gen
        _ = m.handle(.pauseFired(gen: g))
        _ = m.handle(.focusChanged)
        XCTAssertEqual(m.handle(.suggestion("late", gen: g)), [])
        XCTAssertFalse(m.isShowing)
    }

    func testFromShowingEachHideInputHidesAndDismisses() {
        let inputs: [L.Input] = [.key(.typing), .key(.dismiss), .focusChanged, .tapReset]
        for input in inputs {
            var m = L.Machine()
            _ = showing(&m)
            let effects = m.handle(input)
            XCTAssertTrue(effects.contains(.hide(.dismissed)), "\(input) \(effects)")
            XCTAssertFalse(m.isShowing, "\(input)")
        }
    }

    func testAcceptWhileShowingSwallowsHidesAndInserts() {
        var m = L.Machine()
        _ = showing(&m)
        XCTAssertEqual(m.handle(.key(.accept)), [.swallow, .hide(.accepted), .accept("hello")])
        XCTAssertFalse(m.isShowing)
    }

    func testAcceptWhenNotShowingNeverAcceptsOrSwallows() {
        var m = L.Machine()
        let effects = m.handle(.key(.accept))
        XCTAssertFalse(effects.contains(where: isAccept))
        XCTAssertFalse(effects.contains(.swallow))
    }

    func testDismissWhileShowingNeverSwallows() {
        // Shift+Tab with a visible suggestion arrives as .dismiss: it hides and never swallows.
        var m = L.Machine()
        _ = showing(&m)
        let effects = m.handle(.key(.dismiss))
        XCTAssertFalse(effects.contains(.swallow))
        XCTAssertFalse(effects.contains(where: isAccept))
    }

    /// 5,000 seeded random sequences of raw events and timer/suggestion inputs.
    /// Invariant: an accept only follows an Option+Tab event while showing; swallow only comes with accept;
    /// at most one fetch between consecutive typing decisions.
    func testInvariantOverRandomSequences() {
        var rng = MachineLCG(state: 0x29_1A7)
        let pool = ["\t", "", "a", "\u{F702}", "\r"]
        let masks = [L.shiftMask, L.controlMask, L.optionMask, L.commandMask]
        var acceptsSeen = 0
        for _ in 0..<5_000 {
            var m = L.Machine()
            var fetchesSinceTyping = 0
            for _ in 0..<40 {
                let before = m.isShowing
                var event: L.KeyEvent? = nil
                let input: L.Input
                let roll = rng.next() % 9
                let genPick = Int(rng.next() % UInt64(m.gen + 2))
                switch roll {
                case 0, 1, 2:
                    var flags: UInt64 = 0
                    for mask in masks where rng.next() % 3 == 0 { flags |= mask }
                    let e = L.KeyEvent(
                        keyCode: Int(rng.next() % 128), flags: flags,
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
                default: input = .stop
                }
                let effects = m.handle(input)
                if case .key(.typing) = input { fetchesSinceTyping = 0 }
                fetchesSinceTyping += effects.filter { if case .fetch = $0 { return true } else { return false } }.count
                XCTAssertLessThanOrEqual(fetchesSinceTyping, 1, "two fetches without typing in between")

                if effects.contains(where: isAccept) {
                    acceptsSeen += 1
                    XCTAssertTrue(before, "accept while not showing")
                    guard let e = event else { return XCTFail("accept without a key event") }
                    XCTAssertTrue(isAcceptPredicate(e, visible: before), "accept from \(e)")
                }
                if effects.contains(.swallow) {
                    XCTAssertTrue(effects.contains(where: isAccept), "swallow without accept")
                }
            }
        }
        // A green check must be able to go red: the accept path has to be exercised.
        XCTAssertGreaterThan(acceptsSeen, 0)
    }
}
