import Foundation

/// Pure state machine for ghost-text completion. Every input returns the effects the app must run;
/// generations make late replies from an older context harmless.
enum GhostTextLogic {
    enum Key: Equatable { case shiftTab, escape, command, other }

    enum State: Equatable {
        case idle
        case waiting(gen: Int)
        case requesting(gen: Int)
        case showing(text: String, gen: Int)
    }

    enum Input: Equatable {
        case key(Key)
        case pauseFired(gen: Int)
        case snapshotFailed(gen: Int)
        case suggestion(String?, gen: Int)
        case focusChanged
        case stop
    }

    enum Effect: Equatable {
        case scheduleTimer(gen: Int)
        case cancelTimer
        case fetch(gen: Int)
        case show(String)
        case hide
        case accept(String)
        case swallow
    }

    struct Machine: Equatable {
        private(set) var state: State = .idle
        private(set) var gen = 0

        private var isShowing: Bool {
            if case .showing = state { return true }
            return false
        }

        mutating func handle(_ input: Input) -> [Effect] {
            switch input {
            case .key(.shiftTab):
                if case .showing(let text, _) = state {
                    state = .idle
                    return [.swallow, .hide, .accept(text)]
                }
                state = .idle
                return [.cancelTimer]

            case .key(.escape):
                switch state {
                case .showing:
                    state = .idle
                    return [.hide]
                case .waiting, .requesting:
                    state = .idle
                    return [.cancelTimer]
                case .idle:
                    return []
                }

            case .key(.command):
                let hide: [Effect] = isShowing ? [.hide] : []
                state = .idle
                return hide + [.cancelTimer]

            case .key(.other):
                gen += 1
                let hide: [Effect] = isShowing ? [.hide] : []
                state = .waiting(gen: gen)
                return hide + [.scheduleTimer(gen: gen)]

            case .pauseFired(let g):
                guard case .waiting(let current) = state, current == g else { return [] }
                state = .requesting(gen: g)
                return [.fetch(gen: g)]

            case .snapshotFailed(let g), .suggestion(nil, let g):
                guard case .requesting(let current) = state, current == g else { return [] }
                state = .idle
                return []

            case .suggestion(let text?, let g):
                guard case .requesting(let current) = state, current == g else { return [] }
                state = .showing(text: text, gen: g)
                return [.show(text)]

            case .focusChanged, .stop:
                gen += 1
                let hide: [Effect] = isShowing ? [.hide] : []
                state = .idle
                return hide + [.cancelTimer]
            }
        }
    }
}
