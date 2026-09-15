//
//  ClaudeUsagePanel.swift
//  boringNotch
//
//  What went through the proxy, who served it, and how much plan is left.
//

import SwiftUI

/// Four columns answering four different questions about the same log: how much, from whom,
/// how much quota is left, and which models are actually being served.
///
/// The last column is why there is no separate model-router page. A model list on its own is
/// two rows of text — not a panel — and the question it answers ("why is this costing what it
/// is") only makes sense beside the spend it belongs to.
struct ClaudeUsagePanel: View {
    @ObservedObject private var usage = RouterUsageManager.shared
    @ObservedObject private var models = RouterModelLog.shared

    private enum Copy {
        static let grant = "Grant the proxy folder in Settings to read usage"
        static let reading = "Reading the proxy request log"
        // Names the fix, not the file, for the same reason `grant` does two branches
        // down: a filename in a readout looks like a bug report the user cannot act on.
        // Length is a hard constraint here and not a style choice — `PanelRow` is one
        // line with a tail truncation in a 150 pt column, so the old string rendered as
        // "rate-limits.json not rea…" and said nothing at all. Same length as
        // `noUpstreams`, which is known to fit.
        static let noLimits = "Grant folder in Settings"
        static let noModels = "No requests in the recent window"
        static let noUpstreams = "Nothing routed this week"
    }

    var body: some View {
        Group {
            if usage.needsAuthorization {
                // The sandbox, not a missing file — and the fix is a button in Settings, so
                // say which one rather than reporting a path that looks like a bug.
                PanelState(kind: .failed, message: Copy.grant)
            } else if !usage.isAvailable {
                PanelState(kind: .probing, message: Copy.reading)
            } else {
                columns
            }
        }
        // `refresh()` is a single read with no timer behind it, so unlike `start()`/`stop()`
        // there is no sampling lifecycle for the host to own. The host already refreshes
        // `RouterUsageManager` in `NotchPanel.activate()`; this is the same shot for the log's
        // other half.
        .onAppear { models.refresh() }
        .onChange(of: usage.totals(for: .today).requests) { _, _ in models.refresh() }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 6) {
            tokens
            upstreams
            limits
            recentModels
            Spacer(minLength: 0)
        }
    }

    // MARK: Columns

    /// Billed tokens, not the total. Cache reads outrun real work by two orders of magnitude
    /// on a normal day, so folding them in would read as enormous usage every day and mean
    /// nothing — cache gets its own row.
    private var tokens: some View {
        let today = usage.totals(for: .today)
        let week = usage.totals(for: .week)
        let all = usage.totals(for: .all)
        let widest = Self.tokenWidth(
            across: [today.billedTokens, week.billedTokens, all.billedTokens, all.cachedTokens])

        return PanelColumn(title: "TOKENS", width: 112) {
            PanelRow(label: "Today", value: Self.compact(today.billedTokens, widest: widest))
            PanelRow(label: "Week", value: Self.compact(week.billedTokens, widest: widest))
            PanelRow(label: "All time", value: Self.compact(all.billedTokens, widest: widest))
            PanelRow(label: "Cached", value: Self.compact(all.cachedTokens, widest: widest))
            PanelRow(
                label: "Spent",
                value: all.cost > 0 ? String(format: "$%.2f", all.cost) : "$0.00")
        }
    }

    private var upstreams: some View {
        // A provider at zero spends a row to say nothing.
        let ranked = usage.byUpstream(for: .week)
            .filter { $0.value.billedTokens > 0 }
            .sorted { $0.value.billedTokens > $1.value.billedTokens }
        let widest = Self.tokenWidth(across: ranked.map { $0.value.billedTokens })

        return PanelColumn(title: "BY UPSTREAM · WEEK", width: 132) {
            if ranked.isEmpty {
                PanelRow(label: Copy.noUpstreams, value: "—")
            } else {
                ForEach(ranked.prefix(4), id: \.key) { entry in
                    PanelRow(
                        label: entry.key,
                        value: Self.compact(entry.value.billedTokens, widest: widest))
                }
            }
        }
    }

    /// Quota, not money — the proxy sees tokens, never the plan. Claude's meters come from
    /// the `rate-limits.json` the statusline writes beside the log, Kimi's from the
    /// `kimi-limits.json` the router writes after each Kimi request.
    private var limits: some View {
        PanelColumn(title: "PLAN LIMITS", width: 150) {
            if usage.limits == nil && usage.kimiLimits == nil {
                PanelRow(label: Copy.noLimits, value: "—")
            } else {
                // A countdown that never counts is just a stale number. Thirty seconds is
                // finer than the minute the figure is printed to, so it is never visibly wrong.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        if let limits = usage.limits {
                            limitRow(
                                "Claude 5h", percent: limits.fiveHourPercent,
                                resetsAt: limits.fiveHourResetsAt, now: context.date)
                            limitRow(
                                "Claude 7d", percent: limits.sevenDayPercent,
                                resetsAt: limits.sevenDayResetsAt, now: context.date)
                        }
                        if let kimi = usage.kimiLimits {
                            limitRow(
                                "Kimi 5h", percent: kimi.fiveHourPercent,
                                resetsAt: kimi.fiveHourResetsAt, now: context.date)
                            limitRow(
                                "Kimi month", percent: kimi.monthPercent,
                                resetsAt: kimi.monthResetsAt, now: context.date)
                        }
                    }
                }
            }
        }
    }

    /// One window, one row. The bar is the row's own filled background, which buys it the
    /// full column width — the strongest proportion signal the column can draw, at one row
    /// per window instead of the three lines a label/bar/RESETS IN stack needed. The plan
    /// lives in the label rather than in a group header: a header spends a whole row saying
    /// what four labels say for free. Percent keeps the severity tint as the alarm channel;
    /// the countdown sits dimmer, secondary to the number it qualifies.
    private func limitRow(_ label: String, percent: Double, resetsAt: Date?, now: Date) -> some View {
        let fraction = min(max(percent / 100, 0), 1)
        let tint = StatsPalette.severity(fraction)
        return HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 4)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
            Text(" · " + Self.countdown(to: resetsAt, from: now))
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.07))
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.35))
                        .frame(width: max(2, proxy.size.width * fraction))
                        .animation(.smooth(duration: 0.35), value: fraction)
                }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(Int(percent.rounded())) percent")
    }

    /// The small caps head one group of rows shares — a name at this weight reads as a
    /// heading rather than as a row.
    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.4))
    }

    /// Grouped by upstream because a bare model name does not say who is serving it, and
    /// "which provider gave me this" is half the question.
    private var recentModels: some View {
        let grouped = models.byUpstream(upstreams: 2, modelsEach: 2)

        return PanelColumn(title: "RECENT MODELS", width: 156) {
            if grouped.isEmpty {
                PanelRow(label: Copy.noModels, value: "—")
            } else {
                ForEach(grouped, id: \.upstream) { group in
                    groupTitle(group.upstream.uppercased())
                    ForEach(group.models) { entry in
                        PanelRow(
                            label: RouterModelLog.short(entry.model),
                            value: Self.calls(entry.requests))
                    }
                }
            }
        }
    }

    // MARK: Formatting

    /// Same ramp the stats strip uses, so a figure means the same thing in both places.
    private static func compact(_ count: Int) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.1fB", Double(count) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }

    /// Padded to the widest figure this column can hold, so a value crossing from `931K` to
    /// `1.2M` keeps the same width. `PanelRow` is trailing-aligned and monospaced-digit, which
    /// fixes the width of a digit but not how many of them there are.
    ///
    /// Padded with U+2007 FIGURE SPACE, not a plain space: a figure space is defined to be a
    /// digit wide, so the reservation actually lines up. An ordinary space is narrower and the
    /// columns would still creep.
    private static func compact(_ count: Int, widest: String) -> String {
        pad(compact(count), to: widest.count)
    }

    private static func pad(_ text: String, to width: Int) -> String {
        String(repeating: "\u{2007}", count: max(0, width - text.count)) + text
    }

    /// The reservation is sized to the largest figure actually on this column rather than to
    /// the largest one imaginable — hard-coding `999.9M` reserves room for a hundred million
    /// tokens in a column whose biggest number is 31.5M.
    private static func tokenWidth(across values: [Int]) -> String {
        String(compact(values.max() ?? 0).map { $0.isNumber ? "9" : $0 })
    }

    private static func calls(_ count: Int) -> String {
        pad(count >= 1_000 ? compact(count) : "\(count)", to: 4)
    }

    private static func countdown(to date: Date?, from now: Date) -> String {
        guard let date else { return "—" }
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds >= 86_400 {
            return "\(Int(seconds / 86_400))d \(Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600))h"
        }
        if seconds >= 3_600 {
            return "\(Int(seconds / 3_600))h \(Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60))m"
        }
        return "\(Int(seconds / 60))m"
    }
}
