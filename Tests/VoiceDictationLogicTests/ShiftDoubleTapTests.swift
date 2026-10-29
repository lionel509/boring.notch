import XCTest
@testable import VoiceDictationLogic

private struct TapLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33   // high bits: low bits of an LCG cycle too fast
    }
}

/// #56: two clean Shift taps accept, fired on the second release.
final class ShiftDoubleTapTests: XCTestCase {
    typealias L = GhostTextLogic
    private let shift = GhostTextLogic.shiftMask
    private let cmd = GhostTextLogic.commandMask
    private let opt = GhostTextLogic.optionMask
    private let ctl = GhostTextLogic.controlMask

    /// Feeds (keyCode, flags, time) events in order and returns what each call gave.
    private func run(_ d: inout ShiftDoubleTap, _ events: [(Int, UInt64, TimeInterval)]) -> [Bool] {
        var out: [Bool] = []
        for (key, flags, at) in events {
            out.append(d.flagsChanged(keyCode: key, flags: flags, now: at))
        }
        return out
    }

    /// The flags a real keyboard reports for the held modifier keys, plus the caps-lock bit.
    private func keyboardFlags(_ held: Set<Int>, caps: UInt64) -> UInt64 {
        var f = caps
        if !held.isDisjoint(with: [56, 60]) { f |= GhostTextLogic.shiftMask }
        if !held.isDisjoint(with: [54, 55]) { f |= GhostTextLogic.commandMask }
        if !held.isDisjoint(with: [58, 61]) { f |= GhostTextLogic.optionMask }
        if !held.isDisjoint(with: [59, 62]) { f |= GhostTextLogic.controlMask }
        if held.contains(63) { f |= 0x800000 }
        return f
    }

    // MARK: Clean taps

    func testLeftLeftFiresOnSecondReleaseOnly() {
        var d = ShiftDoubleTap()
        let r = run(&d, [(56, shift, 0), (56, 0, 0.08), (56, shift, 0.16), (56, 0, 0.24)])
        XCTAssertEqual(r, [false, false, false, true])
    }

    func testRightRightFires() {
        var d = ShiftDoubleTap()
        let r = run(&d, [(60, shift, 0), (60, 0, 0.08), (60, shift, 0.16), (60, 0, 0.24)])
        XCTAssertEqual(r, [false, false, false, true])
    }

    func testLeftThenRightFires() {
        var d = ShiftDoubleTap()
        let r = run(&d, [(56, shift, 0), (56, 0, 0.08), (60, shift, 0.16), (60, 0, 0.24)])
        XCTAssertEqual(r, [false, false, false, true])
    }

    func testSecondPressAloneNeverFires() {
        var d = ShiftDoubleTap()
        let r = run(&d, [(56, shift, 0), (56, 0, 0.08), (56, shift, 0.16)])
        XCTAssertEqual(r, [false, false, false])
    }

    func testWindowBoundaryIsInclusiveAtFortyMilliseconds() {
        var late = ShiftDoubleTap()
        XCTAssertEqual(run(&late, [(56, shift, 0), (56, 0, 0.1), (56, shift, 0.2), (56, 0, 0.41)]), [false, false, false, false])
        var exact = ShiftDoubleTap()
        XCTAssertEqual(run(&exact, [(56, shift, 0), (56, 0, 0.1), (56, shift, 0.2), (56, 0, 0.40)]), [false, false, false, true])
    }

    func testTripleTapFiresExactlyOnce() {
        var d = ShiftDoubleTap()
        let r = run(&d, [(56, shift, 0), (56, 0, 0.05), (56, shift, 0.1), (56, 0, 0.15), (56, shift, 0.2), (56, 0, 0.25)])
        XCTAssertEqual(r, [false, false, false, true, false, false])
        XCTAssertEqual(r.filter { $0 }.count, 1)
    }

    func testCapsLockBitNeverBlocksATap() {
        var d = ShiftDoubleTap()
        let caps: UInt64 = 0x10000
        let r = run(&d, [(56, shift | caps, 0), (56, caps, 0.08), (60, shift | caps, 0.16), (60, caps, 0.24)])
        XCTAssertEqual(r, [false, false, false, true])
    }

    // MARK: Things that must reset or never count

    func testTypedCapitalNeverFires() {
        // "A" typed: Shift down, the letter's keyDown resets, Shift up, then one more clean tap.
        var d = ShiftDoubleTap()
        var results: [Bool] = []
        results.append(d.flagsChanged(keyCode: 56, flags: shift, now: 0))
        d.reset()   // letter keyDown
        results.append(d.flagsChanged(keyCode: 56, flags: 0, now: 0.1))
        results.append(d.flagsChanged(keyCode: 56, flags: shift, now: 0.2))
        results.append(d.flagsChanged(keyCode: 56, flags: 0, now: 0.3))
        XCTAssertEqual(results, [false, false, false, false])
    }

    func testShiftChordsWithOtherModifiersNeverFire() {
        var a = ShiftDoubleTap()
        XCTAssertEqual(run(&a, [(56, shift, 0), (55, shift | cmd, 0.05), (56, cmd, 0.1), (55, 0, 0.15)]),
                       [false, false, false, false])
        var b = ShiftDoubleTap()
        XCTAssertEqual(run(&b, [(56, shift | opt, 0), (56, opt, 0.1), (56, shift | opt, 0.2), (56, opt, 0.3)]),
                       [false, false, false, false])
        var c = ShiftDoubleTap()
        XCTAssertEqual(run(&c, [(56, shift | ctl, 0), (56, ctl, 0.1), (56, shift | ctl, 0.2), (56, ctl, 0.3)]),
                       [false, false, false, false])
    }

    func testFnBetweenTapsResets() {
        var d = ShiftDoubleTap()
        let r = run(&d, [(56, shift, 0), (56, 0, 0.08), (63, 0x800000, 0.1), (63, 0, 0.12), (56, shift, 0.16), (56, 0, 0.24)])
        XCTAssertEqual(r, [false, false, false, false, false, false])
    }

    func testOverlappingShiftsNeverFire() {
        // Left goes down, right goes down (both held), right up (left still held), left up.
        var d = ShiftDoubleTap()
        let r = run(&d, [(56, shift, 0), (60, shift, 0.05), (60, shift, 0.1), (56, 0, 0.15)])
        XCTAssertEqual(r, [false, false, false, false])
        // A clean pair afterwards starts from zero, so it still needs both releases.
        XCTAssertEqual(run(&d, [(56, shift, 0.2), (56, 0, 0.3)]), [false, false])
    }

    func testResetClearsAPendingFirstTap() {
        var d = ShiftDoubleTap()
        _ = run(&d, [(56, shift, 0), (56, 0, 0.05)])
        d.reset()
        XCTAssertEqual(run(&d, [(56, shift, 0.1), (56, 0, 0.15)]), [false, false])
    }

    // MARK: Property: a model of the rule agrees with the detector on every event

    /// 5,000 seeded random keyboards. Each step is a modifier press or release (a single Shift at a time),
    /// a letter, a click or a scroll, with 0 to 0.6 s between steps. The model fires exactly when the last four
    /// events since the last reset are a clean press, release, press, release and the first press is within the window.
    func testDetectorAgreesWithModelOnRandomKeyboards() {
        var rng = TapLCG(state: 0x56_0F7)
        let otherModifiers = [54, 55, 58, 59, 61, 62, 63]
        var fires = 0
        var expired = 0
        for _ in 0..<5_000 {
            var d = ShiftDoubleTap()
            var held = Set<Int>()
            let caps: UInt64 = rng.next() % 2 == 0 ? 0x10000 : 0
            var t: TimeInterval = 0
            var log: [(down: Bool, at: TimeInterval)] = []   // clean Shift events since the last reset
            for _ in 0..<60 {
                t += Double(rng.next() % 61) / 100
                let action = rng.next() % 10
                if action < 6 {
                    // Half the modifier events are Shift, so clean taps happen often enough to test the window.
                    let isShift = rng.next() % 2 == 0
                    let key = isShift ? (rng.next() % 2 == 0 ? 56 : 60) : otherModifiers[Int(rng.next() % UInt64(otherModifiers.count))]
                    // Only one Shift at a time: the overlap case has its own test above.
                    if (key == 56 && held.contains(60)) || (key == 60 && held.contains(56)) { continue }
                    // Other modifiers are mostly kept released, so a Shift tap is usually clean.
                    if !isShift && !held.contains(key) && rng.next() % 4 != 0 { continue }
                    let isDown = !held.contains(key)
                    if isDown { held.insert(key) } else { held.remove(key) }
                    let flags = keyboardFlags(held, caps: caps)
                    let isClean = (key == 56 || key == 60) && flags & (cmd | opt | ctl) == 0
                    if isClean { log.append((down: isDown, at: t)) } else { log.removeAll() }
                    let fired = d.flagsChanged(keyCode: key, flags: flags, now: t)
                    var expected = false
                    if isClean && !isDown && log.count >= 4 {
                        let last = Array(log.suffix(4))
                        let pattern = last[0].down && !last[1].down && last[2].down && !last[3].down
                        if pattern {
                            if last[3].at - last[0].at <= ShiftDoubleTap.window { expected = true } else { expired += 1 }
                        }
                    }
                    XCTAssertEqual(fired, expected, "key \(key) down \(isDown) at \(t)")
                    if expected {
                        fires += 1
                        log.removeAll()
                    }
                } else if action < 8 {
                    // Letter keyDown or mouse down (6 and 7 pick one): each resets the detector. 8 and 9 are idle.
                    d.reset()
                    log.removeAll()
                }
            }
        }
        // A green check must be able to go red: both the firing path and the expired-window path are exercised.
        XCTAssertGreaterThan(fires, 0)
        XCTAssertGreaterThan(expired, 0)
    }
}
