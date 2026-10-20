import Foundation

/// Pure push-to-talk reducer. Hold = talk, release = stop. A tap shorter than
/// `tapThreshold` latches hands-free until the next key press.
enum DictationHotkeyLogic {
    enum Event: Equatable {
        case keyDown
        case keyUp
    }

    enum Action: Equatable {
        case start
        case stop
        case none
    }

    struct State: Equatable {
        var recording = false
        var handsFree = false
        var downAt: TimeInterval? = nil
    }

    static let tapThreshold: TimeInterval = 0.3

    static func reduce(_ state: inout State, _ event: Event, at time: TimeInterval) -> Action {
        switch event {
        case .keyDown:
            if !state.recording {
                state = State(recording: true, handsFree: false, downAt: time)
                return .start
            }
            if state.handsFree {
                state = State()
                return .stop
            }
            // Carbon key-repeat while the key is held: already recording.
            return .none
        case .keyUp:
            guard state.recording, !state.handsFree, let down = state.downAt else { return .none }
            if time - down < tapThreshold {
                state.handsFree = true
                state.downAt = nil
                return .none
            }
            state = State()
            return .stop
        }
    }
}
