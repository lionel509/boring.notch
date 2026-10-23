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

// Oracle: a verbatim copy of FnKeyLogic.swift at 71a8a84 (before #22), renamed only.
// The property tests below compare the new classifier against it. Do not edit.
enum LegacyFnKeyLogic {
    static let fnKeyCode = 63
    static let globeKeyCode = 179
    static let spaceKeyCode = 49

    /// One raw event, reduced to what the classifier needs. No keycode leaves this type
    /// except as the key that was pressed, and nothing here is logged or stored.
    enum Input: Equatable {
        case flags(keyCode: Int, fn: Bool, otherModifiers: Bool)
        case keyDown(keyCode: Int, isRepeat: Bool)
        case keyUp(keyCode: Int)
        /// The tap was re-enabled after a timeout: the true fn state from the system.
        case resync(fnDown: Bool)
    }

    struct Output: Equatable {
        var event: DictationHotkeyLogic.Event?
        var swallow: Bool

        static let pass = Output(event: nil, swallow: false)
    }

    struct State: Equatable {
        var fnHeld = false
        var fnDownAt: TimeInterval? = nil
        /// Whether a `.keyDown` was sent for this fn hold, so its close is owed.
        var emittedDown = false
        /// Something other than fn+Space went down during this fn hold.
        var chorded = false
        var latched = false
        /// The Space keyDown was swallowed, so its keyUp (and repeats) must be too.
        var swallowingSpace = false
        /// The last fn hold ended as a latched take, so the reducer is still hands-free.
        var handsFreeOpen = false

        init() {}
    }

    static func classify(_ s: inout State, _ input: Input, at time: TimeInterval) -> Output {
        switch input {
        case let .flags(keyCode, fn, otherModifiers):
            if keyCode == fnKeyCode {
                // fn already held: a repeated fn flag changes nothing. Only a real fn-up, a resync or the Space self-heal closes a hold.
                if fn && s.fnHeld { return .pass }
                if fn && !s.fnHeld {
                    s.fnHeld = true
                    s.fnDownAt = time
                    s.latched = false
                    if otherModifiers {
                        // fn pressed while Command, Control or Shift is held never starts a take.
                        s.chorded = true
                        s.emittedDown = false
                        return .pass
                    }
                    s.chorded = false
                    s.emittedDown = true
                    // A new press starts a fresh take, so no hands-free take is left open.
                    s.handsFreeOpen = false
                    return Output(event: .keyDown, swallow: false)
                }
                if !fn && s.fnHeld {
                    return Output(event: releaseFn(&s, at: time), swallow: false)
                }
                return .pass
            }
            // Another modifier going down during an fn hold makes fn a modifier.
            guard s.fnHeld && otherModifiers && !s.chorded else { return .pass }
            return Output(event: chord(&s), swallow: false)

        case let .keyDown(keyCode, isRepeat):
            if keyCode == spaceKeyCode && !isRepeat {
                if s.fnHeld && !s.chorded {
                    s.swallowingSpace = true
                    if s.latched { return Output(event: nil, swallow: true) }
                    s.latched = true
                    return Output(event: .latch, swallow: true)
                }
                // A fresh press with fn up or already chorded: a Space still marked from a lost keyUp is stale.
                s.swallowingSpace = false
                return .pass
            }
            if keyCode == spaceKeyCode && s.swallowingSpace {
                return Output(event: nil, swallow: true)
            }
            if keyCode == fnKeyCode || keyCode == globeKeyCode { return .pass }
            guard s.fnHeld && !s.chorded else { return .pass }
            return Output(event: chord(&s), swallow: false)

        case let .keyUp(keyCode):
            if keyCode == spaceKeyCode && s.swallowingSpace {
                s.swallowingSpace = false
                return Output(event: nil, swallow: true)
            }
            return .pass

        case let .resync(fnDown):
            if s.fnHeld && !fnDown {
                return Output(event: releaseFn(&s, at: time), swallow: false)
            }
            return .pass
        }
    }

    /// fn was released: decide how the hold closes, then clear the hold.
    private static func releaseFn(_ s: inout State, at time: TimeInterval) -> DictationHotkeyLogic.Event? {
        let event: DictationHotkeyLogic.Event?
        if !s.emittedDown {
            event = nil
        } else if s.latched {
            // The take stays hands-free after fn is released; only the next fn press or abort ends it.
            s.handsFreeOpen = true
            event = .keyUp
        } else if s.chorded {
            event = .cancel
        } else if let down = s.fnDownAt, time - down < DictationHotkeyLogic.tapThreshold {
            // A quick fn tap alone never latches hands-free: that would open the mic on every Globe tap.
            event = .cancel
        } else {
            event = .keyUp
        }
        s.fnHeld = false
        s.fnDownAt = nil
        s.emittedDown = false
        s.chorded = false
        s.latched = false
        return event
    }

    /// Something other than fn+Space went down during the hold. Cancels the take if one is open.
    private static func chord(_ s: inout State) -> DictationHotkeyLogic.Event? {
        s.chorded = true
        return s.emittedDown && !s.latched ? .cancel : nil
    }
}

final class FnKeyAnswerTests: XCTestCase {
    typealias Fn = FnKeyLogic
    typealias Logic = DictationHotkeyLogic
    typealias Legacy = LegacyFnKeyLogic

    private let yCode = 16, nCode = 45, dCode = 2

    private func fnDown(other: Bool = false) -> Fn.Input {
        .flags(keyCode: Fn.fnKeyCode, fn: true, otherModifiers: other)
    }

    private func fnUp() -> Fn.Input {
        .flags(keyCode: Fn.fnKeyCode, fn: false, otherModifiers: false)
    }

    private func armed() -> Fn.State {
        var s = Fn.State()
        s.promptArmed = true
        return s
    }

    private func legacy(_ i: Fn.Input) -> Legacy.Input {
        switch i {
        case let .flags(keyCode, fn, otherModifiers): return .flags(keyCode: keyCode, fn: fn, otherModifiers: otherModifiers)
        case let .keyDown(keyCode, isRepeat): return .keyDown(keyCode: keyCode, isRepeat: isRepeat)
        case let .keyUp(keyCode): return .keyUp(keyCode: keyCode)
        case let .resync(fnDown): return .resync(fnDown: fnDown)
        }
    }

    private func randomInput(_ rng: inout SplitMix64) -> Fn.Input {
        let codes = [16, 45, 2, 49, 63, 179, 0, 12]
        switch Int.random(in: 0..<4, using: &rng) {
        case 0:
            let code = [63, 56, 55].randomElement(using: &rng)!
            return .flags(keyCode: code, fn: Bool.random(using: &rng), otherModifiers: Bool.random(using: &rng))
        case 1:
            return .keyDown(keyCode: codes.randomElement(using: &rng)!, isRepeat: Bool.random(using: &rng))
        case 2:
            return .keyUp(keyCode: codes.randomElement(using: &rng)!)
        default:
            return .resync(fnDown: Bool.random(using: &rng))
        }
    }

    // MARK: Examples

    func testYAnswersYesAndSwallowsTheHold() {
        var s = armed()
        _ = Fn.classify(&s, fnDown(), at: 0)
        let down = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: false), at: 0.1)
        XCTAssertEqual(down, Fn.Output(event: .cancel, swallow: true, answer: .yes))
    }

    func testYRepeatAndKeyUpStaySwallowedWithoutAnswering() {
        var s = armed()
        _ = Fn.classify(&s, fnDown(), at: 0)
        _ = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: false), at: 0.1)
        let repeatOut = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: true), at: 0.2)
        XCTAssertTrue(repeatOut.swallow)
        XCTAssertNil(repeatOut.answer)
        let upOut = Fn.classify(&s, .keyUp(keyCode: yCode), at: 0.3)
        XCTAssertEqual(upOut, Fn.Output(event: nil, swallow: true, answer: nil))
    }

    func testNAnswersNoAndDAnswersNever() {
        var s = armed()
        _ = Fn.classify(&s, fnDown(), at: 0)
        XCTAssertEqual(Fn.classify(&s, .keyDown(keyCode: nCode, isRepeat: false), at: 0.1).answer, .no)
        XCTAssertEqual(Fn.classify(&s, .keyUp(keyCode: nCode), at: 0.2).swallow, true)

        var t = armed()
        _ = Fn.classify(&t, fnDown(), at: 0)
        let d = Fn.classify(&t, .keyDown(keyCode: dCode, isRepeat: false), at: 0.1)
        XCTAssertEqual(d.answer, .never)
        XCTAssertTrue(d.swallow)
    }

    func testYPassesWhenPromptNotArmed() {
        var s = Fn.State()
        _ = Fn.classify(&s, fnDown(), at: 0)
        let out = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: false), at: 0.1)
        XCTAssertFalse(out.swallow)
        XCTAssertNil(out.answer)
        XCTAssertEqual(out.event, .cancel, "the existing fn+Y chord must be unchanged")
    }

    func testYWithoutFnPassesEvenWhenArmed() {
        var s = armed()
        let out = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: false), at: 0)
        XCTAssertEqual(out, Fn.Output(event: nil, swallow: false, answer: nil))
    }

    func testFnCommandYGivesNoAnswer() {
        var s = armed()
        _ = Fn.classify(&s, fnDown(), at: 0)
        _ = Fn.classify(&s, .flags(keyCode: 55, fn: true, otherModifiers: true), at: 0.05)
        let out = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: false), at: 0.1)
        XCTAssertNil(out.answer)
        XCTAssertFalse(out.swallow)
    }

    func testLostYKeyUpDoesNotSwallowAFreshYAfterDisarm() {
        var s = armed()
        _ = Fn.classify(&s, fnDown(), at: 0)
        _ = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: false), at: 0.1)
        _ = Fn.classify(&s, fnUp(), at: 0.2)
        s.promptArmed = false
        _ = Fn.classify(&s, fnDown(), at: 1)
        let out = Fn.classify(&s, .keyDown(keyCode: yCode, isRepeat: false), at: 1.1)
        XCTAssertFalse(out.swallow, "a stale swallow marker from a lost keyUp must not eat a fresh Y")
        XCTAssertNil(out.answer)
    }

    // MARK: Invariants

    /// With the prompt never armed, the new classifier matches the pre-#22 one on every input.
    func testKeyRoutingMatchesLegacyWhenUnarmed() {
        var rng = SplitMix64(state: 0x22_0001)
        for _ in 0..<5000 {
            var old = Legacy.State()
            var new = Fn.State()
            var now: TimeInterval = 0
            for _ in 0..<Int.random(in: 1...60, using: &rng) {
                now += Double.random(in: 0...1, using: &rng)
                let input = randomInput(&rng)
                let oldOut = Legacy.classify(&old, legacy(input), at: now)
                let newOut = Fn.classify(&new, input, at: now)
                XCTAssertEqual(newOut.event, oldOut.event, "event diverged on \(input)")
                XCTAssertEqual(newOut.swallow, oldOut.swallow, "swallow diverged on \(input)")
                XCTAssertNil(newOut.answer, "answered while unarmed on \(input)")
            }
        }
    }

    /// With the prompt armed at random between inputs: events never change, swallow changes only for Y/N/D
    /// key events, and an answer only comes from a fresh Y/N/D press while fn is held alone.
    func testArmedKeysOnlyAddSwallowAndAnswer() {
        var rng = SplitMix64(state: 0x22_0002)
        let answerKeys: Set<Int> = [16, 45, 2]
        for _ in 0..<5000 {
            var old = Legacy.State()
            var new = Fn.State()
            var now: TimeInterval = 0
            for _ in 0..<Int.random(in: 1...60, using: &rng) {
                now += Double.random(in: 0...1, using: &rng)
                new.promptArmed = Bool.random(using: &rng)
                let input = randomInput(&rng)
                let fnHeldAlone = old.fnHeld && !old.chorded
                let wasArmed = new.promptArmed
                let oldOut = Legacy.classify(&old, legacy(input), at: now)
                let newOut = Fn.classify(&new, input, at: now)
                XCTAssertEqual(newOut.event, oldOut.event, "event diverged on \(input)")
                if newOut.swallow != oldOut.swallow {
                    switch input {
                    case let .keyDown(keyCode, _), let .keyUp(keyCode):
                        XCTAssertTrue(answerKeys.contains(keyCode), "swallow changed on non-answer key \(keyCode)")
                    default:
                        XCTFail("swallow changed on \(input)")
                    }
                }
                if newOut.answer != nil {
                    guard case let .keyDown(keyCode, isRepeat) = input else {
                        return XCTFail("answer from a non-keyDown: \(input)")
                    }
                    XCTAssertTrue(answerKeys.contains(keyCode))
                    XCTAssertFalse(isRepeat)
                    XCTAssertTrue(fnHeldAlone, "answered without fn held alone")
                    XCTAssertTrue(wasArmed, "answered while unarmed")
                }
            }
        }
    }
}
