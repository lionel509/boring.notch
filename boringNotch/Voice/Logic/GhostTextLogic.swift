import Foundation

/// Pure state machine for ghost-text completion. Every input returns the effects the app must run;
/// generations make late replies from an older context harmless.
enum GhostTextLogic {
    /// One key event as the event tap sees it. `flags` is the raw CGEventFlags value.
    struct KeyEvent: Equatable {
        var keyCode: Int
        var flags: UInt64
        var isKeyDown: Bool
        var isAutorepeat: Bool
        var isSynthetic: Bool
        var characters: String
    }

    enum KeyDecision: Equatable { case accept, typing, dismiss, ignore }

    enum HideReason: Equatable { case accepted, dismissed }

    static let shiftMask: UInt64 = 0x20000
    static let controlMask: UInt64 = 0x40000
    static let optionMask: UInt64 = 0x80000
    static let commandMask: UInt64 = 0x100000

    /// Classifies a key event. Only a real Option+Tab keyDown (no shift, cmd or ctrl, not a repeat)
    /// accepts, and only while a suggestion is visible. Everything else passes through.
    static func decide(_ e: KeyEvent, suggestionVisible: Bool) -> KeyDecision {
        // 1. Our own events, key releases and the modifier keys themselves never change state.
        if e.isSynthetic || !e.isKeyDown || (54...63).contains(e.keyCode) { return .ignore }
        // 2. Option+Tab, and nothing else, accepts.
        let optionOnly = e.flags & optionMask != 0 && e.flags & (shiftMask | commandMask | controlMask) == 0
        if e.keyCode == 48 && optionOnly && !e.isAutorepeat && suggestionVisible { return .accept }
        // 3. Command and control chords always dismiss.
        if e.flags & (commandMask | controlMask) != 0 { return .dismiss }
        // 4. Printable text keeps the pause timer running.
        let isControlOrPrivate = { (s: Unicode.Scalar) -> Bool in
            let category = s.properties.generalCategory
            return category == .control || category == .privateUse
        }
        if !e.characters.isEmpty && !e.characters.unicodeScalars.contains(where: isControlOrPrivate) {
            return .typing
        }
        // 5. Tab, Return, Escape, arrows, Delete and anything else dismiss.
        return .dismiss
    }

    enum State: Equatable {
        case idle
        case waiting(gen: Int)
        case requesting(gen: Int)
        case showing(text: String, gen: Int)
    }

    enum Input: Equatable {
        case key(KeyDecision)
        case pauseFired(gen: Int)
        case snapshotFailed(gen: Int)
        case suggestion(String?, gen: Int)
        case focusChanged
        case tapReset
        case stop
    }

    enum Effect: Equatable {
        case scheduleTimer(gen: Int)
        case cancelTimer
        case cancelFetch
        case fetch(gen: Int)
        case show(String)
        case hide(HideReason)
        case accept(String)
        case swallow
    }

    /// What the app remembers about the caret when a suggestion was requested.
    struct Anchor: Equatable {
        var bundleID: String
        var caretLocation: Int
        var contextTail: String
    }

    /// Insert-time guard: same app, caret still at the end of the field and at the anchored location,
    /// and the last 64 characters before the caret unchanged.
    static func insertAllowed(anchor: Anchor, now: GhostTextSnapshot) -> Bool {
        now.bundleID == anchor.bundleID
            && now.caretAtEnd
            && now.caretLocation == anchor.caretLocation
            && now.textBeforeCaret.map { String($0.suffix(64)) } == anchor.contextTail
    }

    struct Machine: Equatable {
        private(set) var state: State = .idle
        private(set) var gen = 0

        var isShowing: Bool {
            if case .showing = state { return true }
            return false
        }

        mutating func handle(_ input: Input) -> [Effect] {
            switch input {
            case .key(.ignore):
                return []

            case .key(.accept):
                if case .showing(let text, _) = state {
                    gen += 1
                    state = .idle
                    return [.swallow, .hide(.accepted), .accept(text)]
                }
                return dismiss()

            case .key(.typing):
                gen += 1
                let hide: [Effect] = isShowing ? [.hide(.dismissed)] : []
                state = .waiting(gen: gen)
                return hide + [.cancelFetch, .scheduleTimer(gen: gen)]

            case .key(.dismiss), .focusChanged, .tapReset, .stop:
                return dismiss()

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
            }
        }

        private mutating func dismiss() -> [Effect] {
            gen += 1
            let hide: [Effect] = isShowing ? [.hide(.dismissed)] : []
            state = .idle
            return hide + [.cancelTimer]
        }
    }
}
