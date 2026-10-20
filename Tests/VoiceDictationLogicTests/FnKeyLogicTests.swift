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

    private func out(_ event: Logic.Event?, swallow: Bool = false) -> Out {
        Out(event: event, swallow: swallow)
    }

    /// Feeds timed inputs through one classifier state and returns every output.
    private func run(_ steps: [(Fn.Input, TimeInterval)]) -> [Out] {
        var s = Fn.State()
        return steps.map { Fn.classify(&s, $0.0, at: $0.1) }
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

    func testResyncClearsASpaceWhoseKeyUpWasLost() {
        XCTAssertEqual(run([
            (fnDown(), 0),
            (.keyDown(keyCode: 49, isRepeat: false), 0.1),
            (fnUp(), 0.2),
            (.resync(fnDown: false), 0.3),
            (.keyDown(keyCode: 49, isRepeat: false), 5.0),
        ]), [out(.keyDown), out(.latch, swallow: true), out(.keyUp), .pass, .pass])
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

                // Invariant 2: a fn hold that touched another key or modifier never ends in
                // a paste (.stop) unless it latched hands-free first. Checked against the
                // hold as it was before this input.
                if action == .stop {
                    XCTAssertTrue(hold.latched || !hold.chorded, "chorded fn take was pasted")
                }

                // Rebuild the fn hold from the physical stream, for the checks above.
                if fnPressed {
                    let otherDown = anyOtherModifier(held)
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
