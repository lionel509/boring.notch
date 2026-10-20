import XCTest
@testable import VoiceDictationLogic

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class DictationHotkeyLogicTests: XCTestCase {
    typealias Logic = DictationHotkeyLogic

    func testHoldEmitsStartThenStop() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.5), .stop)
        XCTAssertFalse(s.recording)
    }

    func testTapStartsHandsFree() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertTrue(s.handsFree)
        XCTAssertTrue(s.recording)
    }

    func testTapThenTapStopsHandsFree() {
        var s = Logic.State()
        var actions: [Logic.Action] = []
        actions.append(Logic.reduce(&s, .keyDown, at: 0))
        actions.append(Logic.reduce(&s, .keyUp, at: 0.1))
        actions.append(Logic.reduce(&s, .keyDown, at: 1.0))
        actions.append(Logic.reduce(&s, .keyUp, at: 1.1))
        XCTAssertEqual(actions, [.start, .none, .stop, .none])
        XCTAssertFalse(s.recording)
    }

    func testRepeatKeyDownDuringHoldIsIgnored() {
        var s = Logic.State()
        _ = Logic.reduce(&s, .keyDown, at: 0)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0.05), .none)
        XCTAssertEqual(s.recording, true)
        XCTAssertEqual(s.handsFree, false)
        XCTAssertEqual(s.downAt, 0)
    }

    /// Breaker U1-B1: the key is still down when the hands-free take is stopped.
    func testAutoRepeatWhileStoppingHandsFreeDoesNotRestart() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 1.0), .stop)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 1.5), .none, "repeat restarted recording")
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 1.6), .none)
        XCTAssertFalse(s.recording)
    }

    /// Breaker U3-B2: a repeat 30 ms after the stop tap must not start a new take.
    func testRepeatAfterHandsFreeStopIsIgnored() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 2.0), .stop)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 2.03), .none, "repeat restarted recording")
        XCTAssertFalse(s.recording)
    }

    /// Breaker U1-B2: a lost keyUp must not swallow the next press. A fresh press
    /// during a stuck hold-take ends that take (ruling for FIX 1c).
    func testLostKeyUpDoesNotSwallowNextPress() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 10), .stop)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 10.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 12), .start, "second press swallowed")
    }

    func testRepeatsDuringLongHoldAreIgnored() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        for step in 1...10 {
            XCTAssertEqual(Logic.reduce(&s, .keyDown, at: Double(step) * 0.5), .none)
        }
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 5.1), .stop)
        XCTAssertFalse(s.recording)
    }

    func testTimeoutEndsHandsFreeTake() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .timeout, at: 180), .stop)
        XCTAssertFalse(s.recording)
        XCTAssertFalse(s.handsFree)
    }

    func testTimeoutWhileIdleIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .timeout, at: 180), .none)
        XCTAssertEqual(s, Logic.State())
    }

    func testKeyUpWhenIdleIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0), .none)
        XCTAssertEqual(s, Logic.State())
    }

    func testRandomSequencesPairStartsAndStops() {
        var rng = SplitMix64(state: 0x3D1C)
        for _ in 0..<500 {
            var s = Logic.State()
            var time: TimeInterval = 0
            var starts = 0
            var stops = 0
            let count = Int.random(in: 1...40, using: &rng)
            for _ in 0..<count {
                time += Double.random(in: 0...2, using: &rng)
                let event: Logic.Event
                switch Int.random(in: 0...2, using: &rng) {
                case 0: event = .keyDown
                case 1: event = .keyUp
                default: event = .timeout
                }
                let wasRecording = s.recording
                let action = Logic.reduce(&s, event, at: time)
                switch action {
                case .start:
                    XCTAssertFalse(wasRecording, "start emitted while recording")
                    starts += 1
                case .stop:
                    XCTAssertTrue(wasRecording, "stop emitted while idle")
                    stops += 1
                case .discard:
                    XCTFail("discard emitted without a cancel event")
                case .none:
                    break
                }
            }
            XCTAssertEqual(starts - stops, s.recording ? 1 : 0, "start/stop pairing broken")
        }
    }

    // MARK: fn-key events (.latch, .cancel, .discard)

    func testLatchDuringHoldGoesHandsFree() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .latch, at: 0.2), .none)
        XCTAssertTrue(s.handsFree)
        XCTAssertTrue(s.recording)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 1.0), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 3.0), .stop)
        XCTAssertFalse(s.recording)
    }

    func testLatchWhenIdleIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .latch, at: 0), .none)
        XCTAssertEqual(s, Logic.State())
    }

    func testLatchDuringHandsFreeIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .latch, at: 0.5), .none)
        XCTAssertTrue(s.handsFree)
        XCTAssertTrue(s.recording)
    }

    func testCancelDuringHoldDiscards() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .cancel, at: 0.1), .discard)
        XCTAssertFalse(s.recording)
        XCTAssertFalse(s.keyHeld)
    }

    func testCancelDuringHandsFreeIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .cancel, at: 0.5), .none)
        XCTAssertTrue(s.recording)
        XCTAssertTrue(s.handsFree)
    }

    func testCancelWhenIdleIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .cancel, at: 0), .none)
        XCTAssertEqual(s, Logic.State())
    }

    /// A cancelled hold must not leave keyHeld set, or the 2 s repeat window
    /// would swallow the next real press.
    func testFreshPressAfterCancelStarts() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .cancel, at: 0.1), .discard)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0.5), .start, "press after cancel swallowed as repeat")
    }

    func testRandomSequencesWithFnEventsPairStartsAndClosers() {
        var rng = SplitMix64(state: 0x0FA7)
        for _ in 0..<500 {
            var s = Logic.State()
            var time: TimeInterval = 0
            var starts = 0
            var closers = 0
            let count = Int.random(in: 1...40, using: &rng)
            for _ in 0..<count {
                time += Double.random(in: 0...2, using: &rng)
                let event: Logic.Event
                switch Int.random(in: 0...4, using: &rng) {
                case 0: event = .keyDown
                case 1: event = .keyUp
                case 2: event = .latch
                case 3: event = .cancel
                default: event = .timeout
                }
                let wasRecording = s.recording
                let action = Logic.reduce(&s, event, at: time)
                switch action {
                case .start:
                    XCTAssertFalse(wasRecording, "start emitted while recording")
                    starts += 1
                case .stop, .discard:
                    XCTAssertTrue(wasRecording, "\(action) emitted while idle")
                    closers += 1
                case .none:
                    break
                }
                if event == .latch {
                    XCTAssertEqual(action, .none, "latch must never start or stop")
                }
                if event == .cancel {
                    XCTAssertTrue(action == .discard || action == .none, "cancel must only discard")
                }
            }
            XCTAssertEqual(starts - closers, s.recording ? 1 : 0, "start/close pairing broken")
        }
    }
}
