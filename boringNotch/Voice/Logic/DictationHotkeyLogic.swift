import Foundation

/// Pure push-to-talk reducer. Hold = talk, release = stop. A tap shorter than
/// `tapThreshold` latches hands-free until the next key press. A take also ends
/// on its own after `maxTake` seconds, so a forgotten take cannot keep the mic open.
/// The fn key adds `.latch` (fn+Space turns a running hold hands-free) and `.cancel`
/// (fn was a modifier, or a quick fn tap): `.cancel` throws the take away with `.discard`.
/// `.abort` (the setting was turned off) throws away any running take, hands-free included.
/// A release, or a press that ends a take, less than `minHold` after the take started
/// discards it instead of stopping it, so a short accidental press never pastes.
/// `.timeout` always stops. A latched take keeps its start time.
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
        /// When the running take started. Kept through a latch, cleared when the take ends.
        var startedAt: TimeInterval? = nil
    }

    static let tapThreshold: TimeInterval = 0.3
    /// A take released sooner than this after it started is discarded, never pasted.
    static let minHold: TimeInterval = 0.5
    /// Auto-repeat of a held key arrives well inside this gap.
    static let repeatGap: TimeInterval = 2.0
    static let maxTake: TimeInterval = 180

    /// The start cue is due once a running take has been recording for `tapThreshold`, held or hands-free.
    /// The press itself stays silent, so a quick fn tap (the Globe key's own job) never clicks, and a
    /// latched take still gets its cue, so the mic is never open without one.
    /// Accepted limit: fn+arrow, fn+Command or fn+F1 pressed after the lead-in still hears the cue; the take is then discarded.
    static func startCueDue(_ state: State, at time: TimeInterval) -> Bool {
        guard state.recording, let started = state.startedAt else { return false }
        return time - started >= tapThreshold
    }

    /// The stop cue (Pop) is due only when the take's start cue (Tink) actually sounded, so a
    /// take that never got its Tink, because the cue was cancelled first, stays silent at release.
    static func stopCueDue(afterStartCue sounded: Bool) -> Bool {
        sounded
    }

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

    /// Ends a running take on a release or a press. Shorter than `minHold` discards.
    private static func closeAfterHold(_ state: inout State, at time: TimeInterval) -> Action {
        let tooShort = state.startedAt.map { time - $0 < minHold } == true
        state.recording = false
        state.handsFree = false
        state.downAt = nil
        state.startedAt = nil
        return tooShort ? .discard : .stop
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
                state.startedAt = time
                return .start
            }
            // Hands-free stop, or a fresh press after a lost keyUp: either way one press ends the take.
            return closeAfterHold(&state, at: time)
        case .keyUp:
            track(&state, .keyUp, at: time)
            guard state.recording, !state.handsFree, let down = state.downAt else { return .none }
            if time - down < tapThreshold {
                state.handsFree = true
                state.downAt = nil
                return .none
            }
            return closeAfterHold(&state, at: time)
        case .timeout:
            guard state.recording else { return .none }
            state.recording = false
            state.handsFree = false
            state.downAt = nil
            state.startedAt = nil
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
            state.startedAt = nil
            return .discard
        case .abort:
            track(&state, .abort, at: time)
            guard state.recording else { return .none }
            state.recording = false
            state.handsFree = false
            state.downAt = nil
            state.startedAt = nil
            return .discard
        }
    }
}
