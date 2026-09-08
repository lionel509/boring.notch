//
//  ClaudeSessionManager.swift
//  boringNotch
//
//  Which Claude Code tabs exist right now, and what each one is waiting on.
//

import Foundation

/// The persistent half of the Claude Code hook feed.
///
/// `SystemAlertManager` already turns each hook event into a four-second sneak peek and then
/// forgets it, which answers "what just happened" and nothing else. Three terminals deep into
/// an afternoon the question is "which of these is blocked on me", and that needs state. This
/// is that state; the sneak peeks keep firing exactly as before.
///
/// Everything arriving here came off a URL any process on this machine can send, so it is
/// treated as untrusted the whole way: the caller sanitises the strings, this type caps how
/// many it will hold, and nothing is ever executed or resolved as a path.
@MainActor
final class ClaudeSessionManager: ObservableObject {
    static let shared = ClaudeSessionManager()

    enum State: String, CaseIterable {
        /// SessionStart — a tab opened.
        case started
        /// UserPromptSubmit — it was handed something to do.
        case working
        /// Notification/permission_prompt — blocked until a human answers.
        case needsYou
        /// Notification/idle_prompt — it stopped and is sitting at an empty prompt.
        case waiting
        /// Stop — it finished its turn.
        case done

        /// A `String` property rather than a literal in a `Text`, because `SWIFT_EMIT_LOC_STRINGS`
        /// extracts every literal into the 600 KB `Localizable.xcstrings` and turns each one
        /// into a rebase conflict against upstream.
        var title: String {
            switch self {
            case .started: "Started"
            case .working: "Working"
            case .needsYou: "Needs you"
            case .waiting: "Idle"
            case .done: "Done"
            }
        }

        /// Sort weight. A tab blocked on a permission prompt is the only one costing the user
        /// anything by being further down the list, so it sorts first regardless of age.
        var urgency: Int {
            switch self {
            case .needsYou: 0
            case .waiting: 1
            case .working: 2
            case .started: 3
            case .done: 4
            }
        }
    }

    struct Session: Identifiable, Equatable {
        /// Claude Code's own `session_id`, straight out of the hook payload.
        ///
        /// This is the whole reason the manager exists in the form it does. The label is not
        /// an identity: the hook derives it from `$NOTCH_TAB`, else the transcript's
        /// `ai-title`, else *a gist of the last message*, else the directory — and the gist
        /// changes on every single Stop. Keyed on the label, one tab would pile up in the
        /// list under a new name every time it finished a turn.
        let id: String
        var label: String
        var state: State
        var changedAt: Date
        var cwd: String?
    }

    /// How long a session stays listed without being heard from.
    ///
    /// This is a guess, and it is worth being blunt about why it has to be. The app has no way
    /// to verify a session still exists: it never sees the process, the hook only speaks when
    /// something happens, and a terminal closed with cmd-W fires nothing at all. `SessionEnd`
    /// covers the ordinary exits and is the real mechanism — the TTL exists for the ones that
    /// never send it. Long enough to survive a lunch break, short enough that yesterday's tabs
    /// are gone by morning.
    static let timeToLive: TimeInterval = 8 * 60 * 60

    /// A ceiling on what an arbitrary sender can make this hold. The panel shows eight; the
    /// rest of the room is so a burst does not evict the sessions actually in use.
    static let capacity = 32

    /// Deliberately not persisted. A session id from a previous launch names a tab that is
    /// certainly gone — restoring the list would mean showing sessions that cannot possibly
    /// still be running, which is worse than showing none.
    @Published private(set) var sessions: [Session] = []

    private init() {}

    /// Upserts by session id. An unknown id is a new tab; a known one is that tab changing state.
    func record(
        id: String, label: String, state: State, cwd: String?, at when: Date = Date()
    ) {
        prune(asOf: when)

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].state = state
            sessions[index].changedAt = when
            // A later event can arrive with a worse label than the one already held — the
            // hook falls back to a gist, and a gist can be empty or generic. Only overwrite
            // with something that actually says more.
            if !label.isEmpty, label != Self.placeholderLabel {
                sessions[index].label = label
            }
            if let cwd, !cwd.isEmpty { sessions[index].cwd = cwd }
            return
        }

        sessions.append(
            Session(
                id: id,
                label: label.isEmpty ? Self.placeholderLabel : label,
                state: state,
                changedAt: when,
                cwd: (cwd?.isEmpty ?? true) ? nil : cwd))

        if sessions.count > Self.capacity {
            sessions.sort { $0.changedAt > $1.changedAt }
            sessions.removeLast(sessions.count - Self.capacity)
        }
    }

    /// SessionEnd. Without this the list only ever grows — the TTL would be the sole way out,
    /// so a morning's finished tabs would sit there until mid-afternoon.
    func end(id: String) {
        sessions.removeAll { $0.id == id }
    }

    /// Expired entries are filtered out on read as well as swept on write, so a panel left
    /// open past the TTL empties itself instead of showing stale rows until the next hook
    /// fires. The read is non-mutating on purpose: this is called from a view body, and
    /// touching `@Published` state there is how you get a redraw loop.
    func live(limit: Int = .max, asOf now: Date = Date()) -> [Session] {
        unexpired(asOf: now)
            .sorted {
                $0.state.urgency == $1.state.urgency
                    ? $0.changedAt > $1.changedAt
                    : $0.state.urgency < $1.state.urgency
            }
            .prefix(limit)
            .map { $0 }
    }

    /// How many live sessions there are in total, which is not the same as how many the panel
    /// has room to draw.
    func count(asOf now: Date = Date()) -> Int {
        unexpired(asOf: now).count
    }

    func count(of state: State, asOf now: Date = Date()) -> Int {
        unexpired(asOf: now).filter { $0.state == state }.count
    }

    static let placeholderLabel = "session"

    private func unexpired(asOf now: Date) -> [Session] {
        let cutoff = now.addingTimeInterval(-Self.timeToLive)
        return sessions.filter { $0.changedAt >= cutoff }
    }

    /// The write-side sweep. Reads filter instead of mutating, so this is what actually keeps
    /// the array from carrying a day of dead entries around.
    private func prune(asOf now: Date) {
        let cutoff = now.addingTimeInterval(-Self.timeToLive)
        guard sessions.contains(where: { $0.changedAt < cutoff }) else { return }
        sessions.removeAll { $0.changedAt < cutoff }
    }
}

extension ClaudeSessionManager.State {
    /// The hook's argv verb, which is also the `event=` value on the URL. Kept beside the
    /// state rather than in the app delegate so adding a verb is one edit.
    init?(hookEvent: String) {
        switch hookEvent {
        case "started": self = .started
        case "working": self = .working
        case "waiting": self = .needsYou
        case "stalled": self = .waiting
        case "done": self = .done
        default: return nil
        }
    }
}
