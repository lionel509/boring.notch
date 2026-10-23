import Foundation

/// Pure fn-key classifier. It turns raw key events from the session event tap into
/// `DictationHotkeyLogic` events and says whether the tap should swallow the event.
/// It swallows the Space of an fn+Space chord, and Y/N/D while a call prompt is armed and fn
/// is held alone. The fn key itself always passes through, so the system Globe action is left alone.
enum FnKeyLogic {
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
        /// A fresh Y/N/D press answering the armed call prompt. Nothing else sets it.
        var answer: CallAnswer? = nil

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
        /// A call prompt is on screen, so Y/N/D answer it while fn is held alone.
        var promptArmed = false
        /// The Y/N/D keyDown was swallowed, so its keyUp (and repeats) must be too.
        var swallowingAnswerKey: Int? = nil

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
            var answer: CallAnswer? = nil
            var swallow = false
            if let a = CallAnswer(keyCode: keyCode) {
                if !isRepeat { s.swallowingAnswerKey = nil }            // a fresh press clears a lost keyUp
                if !isRepeat && s.promptArmed && s.fnHeld && !s.chorded {
                    answer = a
                    s.swallowingAnswerKey = keyCode
                }
                swallow = s.swallowingAnswerKey == keyCode
            }
            let event = (s.fnHeld && !s.chorded) ? chord(&s) : nil     // exactly the old event
            return Output(event: event, swallow: swallow, answer: answer)

        case let .keyUp(keyCode):
            if keyCode == spaceKeyCode && s.swallowingSpace {
                s.swallowingSpace = false
                return Output(event: nil, swallow: true)
            }
            if let k = s.swallowingAnswerKey, keyCode == k {
                s.swallowingAnswerKey = nil
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
