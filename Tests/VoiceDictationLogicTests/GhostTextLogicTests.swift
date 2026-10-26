import XCTest
@testable import VoiceDictationLogic

final class GhostTextLogicTests: XCTestCase {
    typealias L = GhostTextLogic

    /// Drives the machine to `.showing("hello", gen: g)` and returns the gen.
    private func showing(_ m: inout L.Machine) -> Int {
        _ = m.handle(.key(.other))
        let g = m.gen
        _ = m.handle(.pauseFired(gen: g))
        _ = m.handle(.suggestion("hello", gen: g))
        return g
    }

    func testShiftTabWhenIdlePassesThrough() {
        var m = L.Machine()
        let effects = m.handle(.key(.shiftTab))
        XCTAssertFalse(effects.contains(.swallow))
        XCTAssertFalse(effects.contains(where: { if case .accept = $0 { return true } else { return false } }))
    }

    func testTypingSchedulesTimerAndPauseFetches() {
        var m = L.Machine()
        XCTAssertEqual(m.handle(.key(.other)), [.scheduleTimer(gen: 1)])
        XCTAssertEqual(m.handle(.pauseFired(gen: 1)), [.fetch(gen: 1)])
        XCTAssertEqual(m.handle(.suggestion("hello", gen: 1)), [.show("hello")])
    }

    func testShiftTabAcceptsOnlyWhileShowing() {
        var m = L.Machine()
        _ = showing(&m)
        XCTAssertEqual(m.handle(.key(.shiftTab)), [.swallow, .hide, .accept("hello")])
        XCTAssertFalse(m.handle(.key(.shiftTab)).contains(.swallow))
    }

    func testEscapeWhileShowingHidesWithoutSwallow() {
        var m = L.Machine()
        _ = showing(&m)
        let effects = m.handle(.key(.escape))
        XCTAssertEqual(effects, [.hide])
        XCTAssertFalse(effects.contains(.swallow))
    }

    func testOtherKeyWhileShowingHidesAndReschedules() {
        var m = L.Machine()
        _ = showing(&m)
        XCTAssertEqual(m.handle(.key(.other)), [.hide, .scheduleTimer(gen: m.gen)])
    }

    func testCommandWhileWaitingCancelsAndIdles() {
        var m = L.Machine()
        _ = m.handle(.key(.other))
        XCTAssertEqual(m.handle(.key(.command)), [.cancelTimer])
        XCTAssertEqual(m.state, .idle)
    }

    func testStaleTimerAndStaleSuggestionAreDropped() {
        var m = L.Machine()
        _ = m.handle(.key(.other))
        _ = m.handle(.key(.other))
        XCTAssertEqual(m.handle(.pauseFired(gen: 1)), [])
        XCTAssertEqual(m.handle(.pauseFired(gen: 2)), [.fetch(gen: 2)])
        XCTAssertEqual(m.handle(.suggestion("x", gen: 1)), [])
        XCTAssertEqual(m.handle(.suggestion("y", gen: 2)), [.show("y")])
    }

    func testFocusChangeDropsLateSuggestion() {
        var m = L.Machine()
        _ = m.handle(.key(.other))
        let g = m.gen
        _ = m.handle(.pauseFired(gen: g))
        _ = m.handle(.focusChanged)
        XCTAssertEqual(m.handle(.suggestion("late", gen: g)), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testNilSuggestionIdlesWithoutShowing() {
        var m = L.Machine()
        _ = m.handle(.key(.other))
        let g = m.gen
        _ = m.handle(.pauseFired(gen: g))
        let effects = m.handle(.suggestion(nil, gen: g))
        XCTAssertFalse(effects.contains(where: { if case .show = $0 { return true } else { return false } }))
        XCTAssertEqual(m.state, .idle)
    }

    func testSnapshotFailureIdles() {
        var m = L.Machine()
        _ = m.handle(.key(.other))
        let g = m.gen
        _ = m.handle(.pauseFired(gen: g))
        _ = m.handle(.snapshotFailed(gen: g))
        XCTAssertEqual(m.state, .idle)
    }
}
