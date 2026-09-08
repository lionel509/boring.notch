//
//  ClaudeSessionsPanel.swift
//  boringNotch
//
//  Every Claude Code tab that has spoken lately, and which one is blocked on you.
//

import SwiftUI

/// The persistent counterpart to the Claude sneak peeks.
///
/// A four-second peek says *something happened*; by the time three terminals are running, the
/// question is which one is waiting on a permission prompt while you were reading a different
/// window. Both are driven by the same hook events — this panel does not replace the peeks,
/// it remembers them.
struct ClaudeSessionsPanel: View {
    @ObservedObject private var sessions = ClaudeSessionManager.shared

    /// Two columns of four. Past eight the rows are too short to read at a glance and the
    /// answer stops being "which tab" and starts being "scroll" — which this box does not do.
    private static let perColumn = 4
    private static let capacity = perColumn * 2

    private enum Copy {
        static let empty = "No Claude sessions in the last 8 hours"
        static let hint = "Hooks announce a tab when it starts, blocks, or finishes"
        static let clear = "NOTHING WAITING"
    }

    var body: some View {
        // Ages have to tick or they are just a stale number, and re-reading on a timer is also
        // what expires a session whose terminal was closed without ever firing SessionEnd.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let live = sessions.live(limit: Self.capacity, asOf: context.date)
            let total = sessions.count(asOf: context.date)
            let needing = sessions.count(of: .needsYou, asOf: context.date)

            if live.isEmpty {
                emptyState
            } else {
                board(live: live, total: total, needing: needing, now: context.date)
            }
        }
    }

    /// Two lines, because an empty list here has two possible causes and only one of them is
    /// worth acting on: nothing has run today, or the hook was never installed. The panel
    /// cannot tell them apart — no session ever calls in to say it exists — so it says what it
    /// knows and then says where the events come from.
    private var emptyState: some View {
        VStack(spacing: 3) {
            PanelState(kind: .empty, message: Copy.empty)
                .frame(maxHeight: 40)
            Text(Copy.hint)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func board(
        live: [ClaudeSessionManager.Session], total: Int, needing: Int, now: Date
    ) -> some View {
        let first = Array(live.prefix(Self.perColumn))
        let second = Array(live.dropFirst(Self.perColumn))
        let overflow = total - live.count

        return HStack(alignment: .top, spacing: 8) {
            // Sorted by urgency before age, so the tab holding up work is always in the
            // top-left corner regardless of when it last spoke.
            column(title: "SESSIONS · \(total)", rows: first, now: now, overflow: 0)
            column(
                title: needing > 0 ? "\(needing) NEED YOU" : Copy.clear,
                rows: second, now: now, overflow: overflow)
            Spacer(minLength: 0)
        }
    }

    private func column(
        title: String, rows: [ClaudeSessionManager.Session], now: Date, overflow: Int
    ) -> some View {
        PanelColumn(title: title, width: 278) {
            ForEach(rows) { session in
                PanelRow(
                    label: session.label,
                    value: Self.reading(session, now: now),
                    tint: Self.accent(session.state),
                    status: Self.status(session.state))
                    // The working directory is the one field that disambiguates two tabs with
                    // the same title, and it is far too long for the row. Hover has it.
                    .help(session.cwd ?? session.id)
            }
            if overflow > 0 {
                PanelRow(label: Self.more(overflow), value: "—")
            }
        }
    }

    // MARK: Formatting

    /// State then age, in one trailing-aligned field.
    ///
    /// The two belong together: "Done" without an age is unreadable when three tabs finished
    /// across an afternoon, and an age without a state says nothing at all. Padded to a fixed
    /// width so the label's truncation point does not shift as a minute ticks over.
    private static func reading(_ session: ClaudeSessionManager.Session, now: Date) -> String {
        let age = elapsed(since: session.changedAt, now: now)
        return session.state.title + " " + String(
            repeating: "\u{2007}", count: max(0, 3 - age.count)) + age
    }

    /// Deliberately coarse. A notch is not a stopwatch, and a two-character age is one that
    /// never resizes the row it sits in.
    private static func elapsed(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3_600))h"
    }

    private static func more(_ count: Int) -> String { "+\(count) more" }

    /// Colour is never the only channel here: the dot differs in fill as well as hue, and the
    /// state is spelled out in the value beside it.
    private static func status(_ state: ClaudeSessionManager.State) -> PanelStatus {
        switch state {
        case .needsYou: .down
        case .waiting: .warn
        case .working, .started: .up
        case .done: .unknown
        }
    }

    private static func accent(_ state: ClaudeSessionManager.State) -> Color? {
        switch state {
        case .needsYou: StatsPalette.critical
        case .waiting: StatsPalette.serious
        case .done: .white.opacity(0.45)
        case .working, .started: nil
        }
    }
}
