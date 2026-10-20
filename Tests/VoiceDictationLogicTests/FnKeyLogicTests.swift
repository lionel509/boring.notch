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

/// The classifier's view of one fn hold, rebuilt from the physical stream alone.
private struct Hold {
    var started = false
    var chorded = false
    var latched = false
}

final class FnKeyLogicTests: XCTestCase {
    typealias Fn = FnKeyLogic
    typealias Out = FnKeyLogic.Output
    typealias Logic = DictationHotkeyLogic

    private func fnDown(other: Bool = false) -> Fn.Input {
        .flags(keyCode: Fn.fnKeyCode, fn: true, otherModifiers: other)
    }

    private func fnUp(other: Bool = false) -> Fn.Input {
        .flags(keyCode: Fn.fnKeyCode, fn: false, otherModifiers: other)
    }

    private func space() -> Fn.Input {
        .keyDown(keyCode: Fn.spaceKeyCode, isRepeat: false)
    }

    private func out(_ event: Logic.Event?, swallow: Bool = false) -> Out {
        Out(event: event, swallow: swallow)
    }

    /// Feeds timed inputs through one classifier state and returns every output.
    private func run(_ steps: [(Fn.Input, TimeInterval)]) -> [Out] {
        var s = Fn.State()
        return steps.map { Fn.classify(&s, $0.0, at: $0.1) }
    }

    /// Feeds timed inputs through the classifier and the reducer. Nil events are skipped, so only real take actions show.
    private func reduced(_ steps: [(Fn.Input, TimeInterval)]) -> [Logic.Action] {
        var s = Fn.State()
        var r = Logic.State()
        var actions: [Logic.Action] = []
        for (input, t) in steps {
            if let event = Fn.classify(&s, input, at: t).event {
                actions.append(Logic.reduce(&r, event, at: t))
            }
        }
        return actions
    }

    /// The tests build inputs from these constants, so a wrong constant would stay green. Pin the Apple codes.
    func testKeyCodesAreTheAppleOnes() {
        XCTAssertEqual(Fn.fnKeyCode, 63)
        XCTAssertEqual(Fn.globeKeyCode, 179)
        XCTAssertEqual(Fn.spaceKeyCode, 49)
    }

    // MARK: fn alone

    func testHoldFnEmitsKeyDownThenKeyUp() {
        XCTAssertEqual(run([(fnDown(), 0), (fnUp(), 1.0)]),
                       [out(.keyDown), out(.keyUp)])
    }

    func testFnTapUnderThresholdCancels() {
        XCTAssertEqual(run([(fnDown(), 0), (fnUp(), 0.1)]),
                       [out(.keyDown), out(.cancel)])
    }

    func testFnThenArrowFDeleteCancelsAndNeverDictates() {
        for code in [123, 122, 51] {
            XCTAssertEqual(run([
                (fnDown(), 0),
                (.keyDown(keyCode: code, isRepeat: false), 0.1),
                (.keyUp(keyCode: code), 0.15),
                (fnUp(), 0.2),
            ]), [out(.keyDown), out(.cancel), .pass, out(.cancel)], "keyCode \(code)")
        }
    }

    func testFnThenCommandCancels() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.flags(keyCode: 55, fn: true, otherModifiers: true), 0.1),
            (.flags(keyCode: 55, fn: true, otherModifiers: false), 0.15),
            (fnUp(), 1.0),
        ]), [out(.keyDown), out(.cancel), .pass, out(.cancel)])
    }

    func testCommandHeldThenFnNeverStartsATake() {
        XCTAssertEqual(run([
            (.flags(keyCode: 55, fn: false, otherModifiers: true), 0),
            (fnDown(other: true), 0.1),
            (fnUp(other: true), 0.5),
        ]), [.pass, .pass, .pass])
    }

    func testFnFlagOnAModifierEventIsNotAnFnEvent() {
        XCTAssertEqual(run([(.flags(keyCode: 55, fn: true, otherModifiers: false), 0)]), [.pass])
    }

    func testGlobeKeyDoesNotChord() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 179, isRepeat: false), 0.1),
            (.keyUp(keyCode: 179), 0.2),
            (fnUp(), 1.0),
        ]), [out(.keyDown), .pass, .pass, out(.keyUp)])
    }

    // MARK: fn + Space

    func testFnSpaceLatchesAndSwallowsOnlyTheSpace() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (.keyDown(keyCode: 49, isRepeat: true), 0.15),
            (.keyUp(keyCode: 49), 0.5),
            (fnUp(), 2.0),
        ]), [
            out(.keyDown),
            out(.latch, swallow: true),
            out(nil, swallow: true),
            out(nil, swallow: true),
            out(.keyUp),
        ])
    }

    func testReleasingFnBeforeSpaceStillSwallowsTheSpaceKeyUp() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (fnUp(), 0.2),
            (.keyUp(keyCode: 49), 0.3),
        ]), [out(.keyDown), out(.latch, swallow: true), out(.keyUp), out(nil, swallow: true)])
    }

    func testSpaceWithoutFnPasses() {
        XCTAssertEqual(run([
            (.keyDown(keyCode: 49, isRepeat: false), 0),
            (.keyUp(keyCode: 49), 0.1),
        ]), [.pass, .pass])
    }

    /// Space was already down before fn, so its auto-repeat under fn is a chord, not a latch.
    func testSpaceHeldBeforeFnCancelsInsteadOfLatching() {
        XCTAssertEqual(run([
            (.keyDown(keyCode: 49, isRepeat: false), 0),
            (fnDown(), 0.1),
            (.keyDown(keyCode: 49, isRepeat: true), 0.2),
            (.keyUp(keyCode: 49), 0.5),
            (fnUp(), 0.6),
        ]), [.pass, out(.keyDown), out(.cancel), .pass, out(.cancel)])
    }

    /// A lost Space keyUp must not swallow the next real press.
    func testLostSpaceKeyUpDoesNotSwallowTheNextPress() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (fnUp(), 0.2),
            (.keyDown(keyCode: 49, isRepeat: false), 5.0),
            (.keyUp(keyCode: 49), 5.1),
        ]), [out(.keyDown), out(.latch, swallow: true), out(.keyUp), .pass, .pass])
    }

    // MARK: stale fn (a lost fn-up or an arrow chord that left the mask set)

    /// Breaker B1: a lost fn-up must not swallow the next fresh fn press. The release after it ends its own hold.
    func testLostFnUpRecoversOnNextRelease() {
        var s = Fn.State()
        XCTAssertEqual(Fn.classify(&s, fnDown(), at: 0), out(.keyDown))
        XCTAssertEqual(Fn.classify(&s, fnDown(), at: 5.0), .pass)   // fn-up was lost in between
        XCTAssertEqual(Fn.classify(&s, fnUp(), at: 5.5), out(.keyUp))
        XCTAssertEqual(Fn.classify(&s, fnDown(), at: 7.0), out(.keyDown))
    }

    /// Breaker R1: a repeated fn flag during a long hold must not stop the take.
    func testR1_duplicateFnFlagDuringLongHoldDoesNotStopTake() {
        var s = Fn.State()
        var r = Logic.State()
        var actions: [Logic.Action] = []
        let steps: [(Fn.Input, TimeInterval)] = [(fnDown(), 0), (fnDown(), 2.5), (fnUp(), 3.0)]
        for (input, t) in steps {
            if let event = Fn.classify(&s, input, at: t).event {
                actions.append(Logic.reduce(&r, event, at: t))
            } else {
                actions.append(.none)   // a nil event is recorded, so an early stop cannot hide in the gap
            }
        }
        XCTAssertEqual(actions, [.start, .none, .stop], "only the real fn-up may stop the take")
    }

    /// Breaker R2: a repeated fn flag during a hands-free (latched) take must not stop it.
    func testR2_duplicateFnFlagDuringLatchedHoldDoesNotStopTake() {
        var s = Fn.State()
        var r = Logic.State()
        var actions: [Logic.Action] = []
        let steps: [(Fn.Input, TimeInterval)] = [(fnDown(), 0), (space(), 0.1), (fnDown(), 2.5)]
        for (input, t) in steps {
            if let event = Fn.classify(&s, input, at: t).event {
                actions.append(Logic.reduce(&r, event, at: t))
            }
        }
        XCTAssertEqual(actions, [.start, .none], "a repeated fn flag must not stop a hands-free take")
    }

    /// A repeated fn flag during a hold changes nothing. Only the real fn-up closes the hold.
    func testRepeatedFnFlagsDuringHoldAreIgnored() {
        var s = Fn.State()
        var outputs: [Out] = []
        let steps: [(Fn.Input, TimeInterval)] = [(fnDown(), 0), (fnDown(), 0.5), (fnDown(), 1.0), (fnDown(), 2.5), (fnUp(), 3.0)]
        for (input, t) in steps {
            outputs.append(Fn.classify(&s, input, at: t))
        }
        XCTAssertEqual(outputs.map { $0.event }, [.keyDown, nil, nil, nil, .keyUp])
        XCTAssertFalse(s.fnHeld)
    }

    /// Breaker F2: an arrow still down when fn is released leaves the fn mask set on the fn-up. The stale hold
    /// ignores repeats while it stays down, and the next real release closes it.
    func testStaleFnAfterArrowChordRecoversOnNextRelease() {
        var s = Fn.State()
        _ = Fn.classify(&s, fnDown(), at: 0.0)
        _ = Fn.classify(&s, .keyDown(keyCode: 124, isRepeat: false), at: 0.2)
        XCTAssertEqual(Fn.classify(&s, .flags(keyCode: Fn.fnKeyCode, fn: true, otherModifiers: false), at: 0.4), .pass)
        _ = Fn.classify(&s, .keyUp(keyCode: 124), at: 0.5)
        XCTAssertEqual(Fn.classify(&s, fnDown(), at: 5.0), .pass)
        XCTAssertEqual(Fn.classify(&s, fnUp(), at: 5.5), out(.cancel))
        XCTAssertEqual(Fn.classify(&s, fnDown(), at: 7.0), out(.keyDown))
    }

    /// A stale latched hold is stopped by the second fn press after a lost fn-up, through the reducer too.
    func testStaleLatchedHoldIsStoppedBySecondFnPress() {
        var s = Fn.State()
        var r = Logic.State()
        var actions: [Logic.Action] = []
        let steps: [(Fn.Input, TimeInterval)] = [
            (fnDown(), 0),
            (space(), 0.2),                                // latches the take
            (fnDown(), 5.0),                               // fn-up was lost: this press is ignored
            (fnUp(), 5.5),                                 // the real release: the take stays hands-free
            (fnDown(), 7.0),                               // the next fn press stops it
        ]
        for (input, t) in steps {
            if let event = Fn.classify(&s, input, at: t).event {
                actions.append(Logic.reduce(&r, event, at: t))
            }
        }
        XCTAssertEqual(actions, [.start, .none, .none, .stop])
    }

    /// A repeated fn flag during a chorded hold changes nothing. Only the real fn-up closes the hold.
    func testRepeatedFnFlagDuringChordedHoldIsIgnored() {
        var s = Fn.State()
        _ = Fn.classify(&s, fnDown(), at: 0)
        _ = Fn.classify(&s, .keyDown(keyCode: 124, isRepeat: false), at: 0.2)
        XCTAssertEqual(Fn.classify(&s, .flags(keyCode: Fn.fnKeyCode, fn: true, otherModifiers: false), at: 0.4), .pass)
        XCTAssertTrue(s.fnHeld)
        XCTAssertEqual(Fn.classify(&s, fnUp(), at: 0.6), out(.cancel))
        XCTAssertFalse(s.fnHeld)
    }

    /// Breaker BF1: a repeated fn flag after fn+Command must not start a take.
    func testFnCmdThenRepeatFlagsDoNotRestart() {
        XCTAssertEqual(reduced([
            (fnDown(other: true), 0),   // fn pressed while Command held: chord, no take
            (fnDown(), 0.5),            // Command released; repeated fn flag
            (fnDown(), 1.0),            // another repeated fn flag, fn still held
            (fnUp(), 3.0),              // real fn-up
        ]), [], "a repeated fn flag restarted a take mid-hold")
    }

    /// Breaker BF2: repeated fn flags after an fn+arrow chord must not start a new take.
    func testFnArrowChordThenRepeatFlagsDoNotRestart() {
        XCTAssertEqual(reduced([
            (fnDown(), 0),
            (.keyDown(keyCode: 123, isRepeat: false), 0.2),   // left arrow under fn: chord cancels
            (fnDown(), 0.5),                                  // repeated fn flag
            (fnDown(), 1.0),                                  // second repeated fn flag
            (fnUp(), 3.0),                                    // real fn-up: the chorded hold ends, no take left
        ]), [.start, .discard, .none], "a repeated fn flag restarted a take after a chord")
    }

    // MARK: resync (tap re-enabled after a timeout)

    func testResyncWhileHeldDoesNothing() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.resync(fnDown: true), 0.5),
            (fnUp(), 1.0),
        ]), [out(.keyDown), .pass, out(.keyUp)])
    }

    func testResyncAfterLostFnUpEndsTheTake() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.resync(fnDown: false), 1.0),
        ]), [out(.keyDown), out(.keyUp)])
    }

    /// A resync while Space is still held must not let its auto-repeat through (breaker B2, F1).
    func testBreakerResyncLetsSpaceRepeatsThroughOnLatchedFnSpace() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (.resync(fnDown: true), 0.5),
            (.keyDown(keyCode: 49, isRepeat: true), 0.6),
        ]).last, out(nil, swallow: true), "Space auto-repeat of a latched fn+Space must stay swallowed")
    }

    /// Breaker F1: the same Space auto-repeat after a tap re-enable, from the monitor-side probe.
    func testBreakSpaceRepeatAfterTapReenableLeaksThrough() {
        XCTAssertEqual(run([
            (fnDown(), 0.0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (.resync(fnDown: true), 0.5),
            (.keyDown(keyCode: 49, isRepeat: true), 0.6),
        ]).last, out(nil, swallow: true))
    }

    /// The Space keyUp after a resync must be swallowed iff its keyDown was (breaker B3).
    func testBreakerResyncLetsOrphanSpaceKeyUpThrough() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (.resync(fnDown: true), 0.5),
            (.keyUp(keyCode: 49), 0.6),
        ]).last, out(nil, swallow: true), "a Space keyUp is swallowed iff its keyDown was")
    }

    /// A Space whose keyUp was lost is cleared by the next fresh Space keyDown, not by resync.
    func testFreshSpaceAfterLostKeyUpAndResyncPasses() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (.resync(fnDown: false), 0.5),
            (.keyDown(keyCode: 49, isRepeat: false), 1.0),
            (.keyUp(keyCode: 49), 1.1),
        ]), [out(.keyDown), out(.latch, swallow: true), out(.keyUp), .pass, .pass])
    }


    // MARK: hands-free still open (so turning the setting off can end it)

    func testHandsFreeOpenAfterLatchedRelease() {
        var s = Fn.State()
        _ = Fn.classify(&s, fnDown(), at: 0)
        _ = Fn.classify(&s, .keyDown(keyCode: 49, isRepeat: false), at: 0.2)
        _ = Fn.classify(&s, .keyUp(keyCode: 49), at: 0.3)
        XCTAssertEqual(Fn.classify(&s, fnUp(), at: 1.0).event, .keyUp)
        XCTAssertTrue(s.handsFreeOpen)
    }

    func testHandsFreeOpenClearedByNextFnPress() {
        var s = Fn.State()
        _ = Fn.classify(&s, fnDown(), at: 0)
        _ = Fn.classify(&s, .keyDown(keyCode: 49, isRepeat: false), at: 0.2)
        _ = Fn.classify(&s, .keyUp(keyCode: 49), at: 0.3)
        _ = Fn.classify(&s, fnUp(), at: 1.0)
        XCTAssertEqual(Fn.classify(&s, fnDown(), at: 3.0).event, .keyDown)
        XCTAssertFalse(s.handsFreeOpen)
    }

    func testPlainHoldNeverSetsHandsFreeOpen() {
        var s = Fn.State()
        _ = Fn.classify(&s, fnDown(), at: 0)
        _ = Fn.classify(&s, fnUp(), at: 1.0)
        XCTAssertFalse(s.handsFreeOpen)
    }

    // MARK: random physical streams

    /// Generates only what a real keyboard produces and checks the plan's invariants on
    /// the classifier and reducer together: swallowing is limited to Space, fn used as a
    /// modifier never dictates, and every start is closed exactly once.
    func testRandomPhysicalStreams() {
        var rng = SplitMix64(state: 0xF00D)
        let fnKey = Fn.fnKeyCode
        let space = Fn.spaceKeyCode
        let modifiers = [fnKey, 55, 59, 56]          // fn, command, control, shift
        let physical = modifiers + [space, 123, 122, 51] // plus space, arrow, F1, delete
        var latches = 0
        var cancels = 0
        var discards = 0
        var stops = 0
        var swallowed = 0

        for _ in 0..<500 {
            var fnState = Fn.State()
            var logic = Logic.State()
            var held = Set<Int>()
            var hold = Hold()
            var holdId = 0
            // The fn hold that owns the open take, and what that hold did while it was current.
            var takeHoldId = -1
            var takeLatched = false
            var takeChorded = false
            var spaceSwallow: Bool? = nil
            var time: TimeInterval = 0
            var starts = 0
            var closers = 0

            for _ in 0..<Int.random(in: 1...60, using: &rng) {
                time += Double.random(in: 0.01...1.0, using: &rng)
                let code = physical.randomElement(using: &rng)!
                let wasHeld = held.contains(code)
                let isModifier = modifiers.contains(code)
                var isKeyDown = false
                var isRepeat = false
                var input: Fn.Input

                if wasHeld {
                    if isModifier || Bool.random(using: &rng) {
                        held.remove(code)
                        input = isModifier
                            ? .flags(keyCode: code, fn: held.contains(fnKey), otherModifiers: anyOtherModifier(held))
                            : .keyUp(keyCode: code)
                    } else {
                        isKeyDown = true
                        isRepeat = true
                        input = .keyDown(keyCode: code, isRepeat: true)
                    }
                } else {
                    held.insert(code)
                    if isModifier {
                        input = .flags(keyCode: code, fn: held.contains(fnKey), otherModifiers: anyOtherModifier(held))
                    } else {
                        isKeyDown = true
                        input = .keyDown(keyCode: code, isRepeat: false)
                    }
                }
                let fnPressed = code == fnKey && !wasHeld
                let fnHeld = held.contains(fnKey)

                let output = Fn.classify(&fnState, input, at: time)

                // Invariant 1: only Space is ever swallowed.
                if output.swallow {
                    swallowed += 1
                    XCTAssertEqual(code, space, "swallowed a non-Space key")
                }
                // Invariant 1b: one physical Space press swallows as a unit.
                if code == space {
                    if !wasHeld {
                        spaceSwallow = output.swallow
                    } else {
                        XCTAssertEqual(output.swallow, spaceSwallow, "space press split between keyDown and keyUp")
                    }
                    if !held.contains(space) { spaceSwallow = nil }
                }

                var action = Logic.Action.none
                if let event = output.event {
                    let wasRecording = logic.recording
                    action = Logic.reduce(&logic, event, at: time)
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
                    if event == .latch { latches += 1 }
                    if event == .cancel { cancels += 1 }
                    if action == .discard { discards += 1 }
                    if action == .stop { stops += 1 }
                }

                // Rebuild the fn hold from the physical stream.
                if fnPressed {
                    let otherDown = anyOtherModifier(held)
                    holdId += 1
                    hold = Hold(started: !otherDown, chorded: otherDown, latched: false)
                } else if fnHeld {
                    if !wasHeld && isModifier && code != fnKey {
                        hold.chorded = true
                    }
                    if isKeyDown && code != space {
                        hold.chorded = true
                    }
                    if !wasHeld && code == space && !hold.chorded {
                        hold.latched = true
                    }
                    if isRepeat && code == space && !hold.latched {
                        hold.chorded = true
                    }
                }

                // Track the hold that owns the open take. A take latched in an earlier hold
                // stays open hands-free, so the current hold is not the right one to check.
                if action == .start {
                    takeHoldId = holdId
                    takeLatched = false
                    takeChorded = false
                }
                if takeHoldId == holdId {
                    takeLatched = takeLatched || hold.latched
                    takeChorded = takeChorded || hold.chorded
                }
                // Invariant 2: a take whose fn hold touched another key or modifier is never
                // pasted (.stop) unless that hold latched hands-free first.
                if action == .stop {
                    XCTAssertTrue(takeLatched || !takeChorded, "chorded fn take was pasted")
                }

                XCTAssertEqual(starts - closers, logic.recording ? 1 : 0, "start/close pairing broken")
            }
            XCTAssertEqual(starts - closers, logic.recording ? 1 : 0, "start/close pairing broken at end of stream")
        }

        // The generator must reach every path, or the invariants above pass vacuously.
        XCTAssertGreaterThan(latches, 0)
        XCTAssertGreaterThan(cancels, 0)
        XCTAssertGreaterThan(discards, 0)
        XCTAssertGreaterThan(stops, 0)
        XCTAssertGreaterThan(swallowed, 0)
    }

    /// Command, control or shift is down. Caps Lock and fn are not counted.
    private func anyOtherModifier(_ held: Set<Int>) -> Bool {
        held.contains(55) || held.contains(59) || held.contains(56)
    }
}
