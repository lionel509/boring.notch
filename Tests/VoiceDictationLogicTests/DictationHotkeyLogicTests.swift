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

    /// Replaces the old "no discard without cancel" check: a release shorter than
    /// `minHold` now ends in `.discard`. The check is that every pasted release is at
    /// least `minHold` long, every discard is shorter, and both branches are reached.
    func testRandomSequencesPairStartsAndStops() {
        var rng = SplitMix64(state: 0x3D1C)
        var totalStops = 0
        var totalDiscards = 0
        for _ in 0..<500 {
            var s = Logic.State()
            var time: TimeInterval = 0
            var startedAt: TimeInterval = 0
            var starts = 0
            var stops = 0
            var discards = 0
            let count = Int.random(in: 1...40, using: &rng)
            for _ in 0..<count {
                time += Double.random(in: 0...1, using: &rng)
                let event: Logic.Event
                switch Int.random(in: 0...3, using: &rng) {
                case 0: event = .keyDown
                case 1: event = .keyUp
                case 2: event = .timeout
                default: event = .latch
                }
                let wasRecording = s.recording
                let action = Logic.reduce(&s, event, at: time)
                switch action {
                case .start:
                    XCTAssertFalse(wasRecording, "start emitted while recording")
                    starts += 1
                    startedAt = time
                case .stop:
                    XCTAssertTrue(wasRecording, "stop emitted while idle")
                    stops += 1
                    if event != .timeout {
                        XCTAssertGreaterThanOrEqual(time - startedAt, Logic.minHold, "release shorter than minHold was pasted")
                    }
                case .discard:
                    XCTAssertTrue(wasRecording, "discard emitted while idle")
                    discards += 1
                    XCTAssertLessThan(time - startedAt, Logic.minHold, "take at least minHold was discarded")
                case .none:
                    break
                }
                XCTAssertEqual(starts - stops - discards, s.recording ? 1 : 0, "start/stop pairing broken")
            }
            totalStops += stops
            totalDiscards += discards
        }
        XCTAssertGreaterThan(totalStops, 0, "no take was ever pasted, so the checks pass vacuously")
        XCTAssertGreaterThan(totalDiscards, 0, "no take was ever discarded, so the checks pass vacuously")
    }

    // MARK: start cue (a quick fn tap stays silent, a held fn cues once the hold is confirmed)

    func testStartCueIsNotDueOnThePressItself() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertFalse(Logic.startCueDue(s, at: 0))
        XCTAssertFalse(Logic.startCueDue(s, at: Logic.tapThreshold - 0.01))
    }

    func testStartCueIsDueOnceAHeldFnPassesTheTapThreshold() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertTrue(Logic.startCueDue(s, at: Logic.tapThreshold))
        XCTAssertTrue(Logic.startCueDue(s, at: 1.5))
    }

    /// A shortcut tap under the threshold latches hands-free; the take is audible, so it still cues.
    func testTapLatchedHandsFreeTakeCues() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertTrue(s.handsFree)
        XCTAssertTrue(Logic.startCueDue(s, at: Logic.tapThreshold))
    }

    /// A quick fn tap is classified as a cancel, so no take exists to cue.
    func testQuickFnTapNeverCues() {
        var fn = FnKeyLogic.State()
        var s = Logic.State()
        let down = FnKeyLogic.classify(&fn, .flags(keyCode: FnKeyLogic.fnKeyCode, fn: true, otherModifiers: false), at: 0)
        if let event = down.event { XCTAssertEqual(Logic.reduce(&s, event, at: 0), .start) } else { XCTFail("fn down emits keyDown") }
        let up = FnKeyLogic.classify(&fn, .flags(keyCode: FnKeyLogic.fnKeyCode, fn: false, otherModifiers: false), at: 0.1)
        if let event = up.event { XCTAssertEqual(Logic.reduce(&s, event, at: 0.1), .discard) } else { XCTFail("fn up emits cancel") }
        XCTAssertFalse(Logic.startCueDue(s, at: 1.0))
    }

    /// Break 1 (review): fn+Space latch inside the lead-in. The take is hands-free before the cue is
    /// due, so the Tink must still come due; the stop Pop must then follow a Tink.
    func testFnSpaceLatchInLeadInStillCues() {
        var fn = FnKeyLogic.State()
        var s = Logic.State()
        var actions: [Logic.Action] = []
        var cueDue: [TimeInterval] = []
        func feed(_ input: FnKeyLogic.Input, at t: TimeInterval) {
            guard let event = FnKeyLogic.classify(&fn, input, at: t).event else { return }
            actions.append(Logic.reduce(&s, event, at: t))
        }
        feed(.flags(keyCode: FnKeyLogic.fnKeyCode, fn: true, otherModifiers: false), at: 0)
        feed(.keyDown(keyCode: FnKeyLogic.spaceKeyCode, isRepeat: false), at: 0.1)
        if Logic.startCueDue(s, at: 0.3) { cueDue.append(0.3) }
        feed(.flags(keyCode: FnKeyLogic.fnKeyCode, fn: false, otherModifiers: false), at: 0.5)
        feed(.flags(keyCode: FnKeyLogic.fnKeyCode, fn: true, otherModifiers: false), at: 2.0)
        feed(.flags(keyCode: FnKeyLogic.fnKeyCode, fn: false, otherModifiers: false), at: 2.1)
        XCTAssertEqual(actions.filter { $0 != .none }, [.start, .stop])
        XCTAssertFalse(cueDue.isEmpty, "stop cue (Pop) played for a take whose start cue (Tink) never came due")
    }

    func testCancelledOrAbortedTakeNeverCues() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .cancel, at: 0.05), .discard)
        XCTAssertFalse(Logic.startCueDue(s, at: 1.0))

        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 2), .start)
        XCTAssertEqual(Logic.reduce(&s, .abort, at: 2.5), .discard)
        XCTAssertFalse(Logic.startCueDue(s, at: 3.0))
    }

    func testIdleStateNeverCues() {
        let s = Logic.State()
        XCTAssertFalse(Logic.startCueDue(s, at: 10))
    }

    // MARK: minimum hold (a release before minHold never pastes)

    func testMinHoldIsHalfASecondAndAboveTheTapLatch() {
        XCTAssertEqual(Logic.minHold, 0.5)
        XCTAssertGreaterThan(Logic.minHold, Logic.tapThreshold)
    }

    func testReleaseBeforeMinHoldDiscards() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.4), .discard)
        XCTAssertFalse(s.recording)
        XCTAssertFalse(s.handsFree)
    }

    func testShortTapStillLatchesHandsFree() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.29), .none)
        XCTAssertTrue(s.handsFree)
        XCTAssertTrue(s.recording)
    }

    func testTapThenShortPressDiscards() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0.4), .discard)
        XCTAssertFalse(s.recording)
    }

    func testTapThenLongPressStops() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 2.0), .stop)
        XCTAssertFalse(s.recording)
    }

    func testLatchThenShortPressDiscards() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .latch, at: 0.1), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.2), .none)
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0.45), .discard)
        XCTAssertFalse(s.recording)
    }

    func testTimeoutAfterShortStartStillStops() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .timeout, at: 0.2), .stop)
        XCTAssertFalse(s.recording)
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

    /// Turning the setting off during a fn take ends it: a hands-free take discards too.
    func testAbortDuringHandsFreeDiscards() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)   // tap: hands-free
        XCTAssertEqual(Logic.reduce(&s, .abort, at: 1.0), .discard)
        XCTAssertFalse(s.recording)
        XCTAssertFalse(s.keyHeld)
    }

    func testAbortDuringHoldDiscards() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .abort, at: 0.5), .discard)
        XCTAssertFalse(s.recording)
    }

    func testAbortWhenIdleIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .abort, at: 0), .none)
        XCTAssertFalse(s.recording)
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
                switch Int.random(in: 0...5, using: &rng) {
                case 0: event = .keyDown
                case 1: event = .keyUp
                case 2: event = .latch
                case 3: event = .cancel
                case 4: event = .timeout
                default: event = .abort
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
