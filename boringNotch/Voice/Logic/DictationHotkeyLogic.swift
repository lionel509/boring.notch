import Foundation

/// Pure push-to-talk reducer. Hold = talk, release = stop. A tap shorter than
/// `tapThreshold` latches hands-free until the next key press. A take also ends
/// on its own after `maxTake` seconds, so a forgotten take cannot keep the mic open.
/// The fn key adds `.latch` (fn+Space turns a running hold hands-free) and `.cancel`
/// (fn was a modifier, or a quick fn tap): `.cancel` throws the take away with `.discard`.
/// `.abort` (the setting was turned off) throws away any running take, hands-free included.
enum DictationHotkeyLogic {
    enum Event: Equatable {
        case keyDown
        case keyUp
        case timeout
        case latch
        case cancel
        case abort
    }

    enum Action: Equatable {
        case start
        case stop
        case discard
        case none
    }

    struct State: Equatable {
        var recording = false
        var handsFree = false
        var downAt: TimeInterval? = nil
        /// Whether the key is down as far as we know. Survives a stop, so a
        /// key still held after a stop is not read as a new press.
        var keyHeld = false
        var lastDownAt: TimeInterval? = nil
    }

    static let tapThreshold: TimeInterval = 0.3
    /// Auto-repeat of a held key arrives well inside this gap.
    static let repeatGap: TimeInterval = 2.0
    static let maxTake: TimeInterval = 180

    /// Records key bookkeeping without deciding anything.
    static func track(_ state: inout State, _ event: Event, at time: TimeInterval) {
        switch event {
        case .keyDown:
            state.keyHeld = true
            state.lastDownAt = time
        case .keyUp, .cancel, .abort:
            state.keyHeld = false
            state.lastDownAt = nil
        case .timeout, .latch:
            break
        }
    }

    static func reduce(_ state: inout State, _ event: Event, at time: TimeInterval) -> Action {
        switch event {
        case .keyDown:
            let isRepeat = state.keyHeld && state.lastDownAt.map { time - $0 < repeatGap } == true
            track(&state, .keyDown, at: time)
            if isRepeat { return .none }
            if !state.recording {
                state.recording = true
                state.handsFree = false
                state.downAt = time
                return .start
            }
            // Hands-free stop, or a fresh press after a lost keyUp: either way one press ends the take.
            state.recording = false
            state.handsFree = false
            state.downAt = nil
            return .stop
        case .keyUp:
            track(&state, .keyUp, at: time)
            guard state.recording, !state.handsFree, let down = state.downAt else { return .none }
            if time - down < tapThreshold {
                state.handsFree = true
                state.downAt = nil
                return .none
            }
            state.recording = false
            state.downAt = nil
            return .stop
        case .timeout:
            guard state.recording else { return .none }
            state.recording = false
            state.handsFree = false
            state.downAt = nil
            return .stop
        case .latch:
            // Only a running hold turns hands-free. When idle, fn+Space must not start a take.
            if state.recording && !state.handsFree {
                state.handsFree = true
                state.downAt = nil
            }
            return .none
        case .cancel:
            track(&state, .cancel, at: time)
            guard state.recording, !state.handsFree else { return .none }
            state.recording = false
            state.handsFree = false
            state.downAt = nil
            return .discard
        case .abort:
            track(&state, .abort, at: time)
            guard state.recording else { return .none }
            state.recording = false
            state.handsFree = false
            state.downAt = nil
            return .discard
        }
    }
}
