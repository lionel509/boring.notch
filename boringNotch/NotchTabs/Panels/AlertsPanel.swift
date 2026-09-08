//
//  AlertsPanel.swift
//  boringNotch
//
//  Everything the homelab has complained about, newest first, and whether the VPN is leaking.
//

import SwiftUI

private enum Caption {
    static let vpn = "VPN EXIT IP"
    static var recent: String { "WARN & CRITICAL · \(HomelabManager.alertWindowHours)h" }
    static let watchdog = "vpn-watchdog"
    static let noVerdict = "no verdict yet"
    static var quiet: String { "Nothing has complained in \(HomelabManager.alertWindowHours)h" }
    static let probing = "Reading the log…"
    static let exitPrefix = "exit_ip: "
}

/// Four rows, because that is what fits without scrolling and because the fifth-oldest
/// warning is not why anyone opened the notch. Lines are long and structured — `check` plus
/// a detail sentence — so they scroll rather than truncate: the tail of a vpn-watchdog line
/// is the half that says what actually happened.
struct AlertsPanel: View {
    @ObservedObject private var homelab = HomelabManager.shared

    private static let visibleRows = 4

    private var recent: [HomelabManager.AlertLine] {
        Array(homelab.alerts.prefix(Self.visibleRows))
    }

    var body: some View {
        Group {
            if let problem = homelab.sourceProblem, homelab.vpnExit == nil, recent.isEmpty {
                PanelState(kind: problem.failed ? .failed : .empty, message: problem.message)
            } else if !homelab.alertsLoaded {
                PanelState(kind: .probing, message: Caption.probing)
            } else {
                content
            }
        }
        .onAppear { homelab.start(.alerts) }
        .onDisappear { homelab.stop(.alerts) }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 20) {
            vpnColumn
            recentColumn
        }
    }

    /// The leak check, given its own column rather than a row in the list. It is the one
    /// line here that is a question about right now rather than a record of the past, and
    /// an `OK` scrolling away under three warnings would bury it.
    private var vpnColumn: some View {
        let width: CGFloat = 214
        let verdict = homelab.vpnExit
        return PanelColumn(title: Caption.vpn, width: width) {
            PanelRow(
                label: Caption.watchdog,
                value: verdict.map { HomelabManager.age(since: $0.date) } ?? Caption.noVerdict,
                tint: verdict.map { tint(for: $0.level) } ?? nil,
                status: verdict.map { status(for: $0.level) } ?? .unknown)
            if let verdict {
                PanelMarqueeLine(text: detail(of: verdict), width: width, tint: tint(for: verdict.level))
            }
        }
    }

    private var recentColumn: some View {
        let width: CGFloat = 350
        return PanelColumn(title: Caption.recent, width: width) {
            if recent.isEmpty {
                PanelRow(label: Caption.quiet, value: "", status: .up)
            } else {
                ForEach(recent) { line in
                    HStack(spacing: 6) {
                        StatusDot(status: status(for: line.level))
                        PanelMarqueeLine(
                            text: "\(line.host) · \(line.text)",
                            width: width - 46,
                            tint: tint(for: line.level))
                        Spacer(minLength: 2)
                        Text(HomelabManager.age(since: line.date))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(height: 15)
                }
            }
        }
    }

    private func detail(of line: HomelabManager.AlertLine) -> String {
        line.text.hasPrefix(Caption.exitPrefix)
            ? String(line.text.dropFirst(Caption.exitPrefix.count))
            : line.text
    }

    private func status(for level: String) -> PanelStatus {
        switch level {
        case "CRITICAL": .down
        case "WARN", "warning": .warn
        case "OK": .up
        default: .unknown
        }
    }

    private func tint(for level: String) -> Color? {
        switch level {
        case "CRITICAL": StatsPalette.critical
        case "WARN", "warning": StatsPalette.serious
        case "OK": StatsPalette.good
        default: nil
        }
    }
}
