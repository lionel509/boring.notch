//
//  FleetPanel.swift
//  boringNotch
//
//  Every guest in the homelab, and how hard the two scraped hosts are working.
//

import SwiftUI

/// Column and row captions. Held as `String` constants rather than written inline, because
/// `SWIFT_EMIT_LOC_STRINGS` extracts every literal reaching a `Text` into the 600 KB
/// `Localizable.xcstrings` and turns each one into a rebase conflict.
private enum Caption {
    static let cpu = "CPU"
    static let memory = "MEM"
    static let load = "LOAD 1m"
    static let root = "ROOT"
    static let probing = "Reaching the homelab…"
    static let nothing = "Neither Prometheus nor Loki knows about any host"
    static let quiet = "silent"
    static let clear = "clear"
    static var guests: String { "GUESTS · \(HomelabManager.livenessWindowMinutes)m" }
}

/// Liveness comes from two different places on purpose. Only two guests run node_exporter,
/// so the other three are judged by whether they are still shipping logs — a box that is
/// still journalling is a box that is still up, and that is the only evidence there is.
struct FleetPanel: View {
    @ObservedObject private var homelab = HomelabManager.shared

    /// Alphabetical, so a guest never swaps rows between refreshes.
    private var guests: [String] {
        Array(Set(homelab.hosts.keys).union(homelab.nodes.keys).sorted().prefix(6))
    }

    /// The scraped hosts, which are the only ones with real numbers behind them.
    private var scraped: [String] {
        homelab.nodes.filter { $0.value.cpu != nil }.keys.sorted()
    }

    var body: some View {
        Group {
            if guests.isEmpty, let problem = homelab.sourceProblem {
                PanelState(kind: problem.failed ? .failed : .empty, message: problem.message)
            } else if guests.isEmpty, !homelab.nodesLoaded {
                PanelState(kind: .probing, message: Caption.probing)
            } else if guests.isEmpty {
                PanelState(kind: .empty, message: Caption.nothing)
            } else {
                content
            }
        }
        // The battery rule: the poller runs only while this panel is the one on screen.
        .onAppear { homelab.start(.nodes) }
        .onDisappear { homelab.stop(.nodes) }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 20) {
            PanelColumn(title: Caption.guests, width: 208) {
                ForEach(guests, id: \.self) { host in
                    PanelRow(
                        label: host,
                        value: summary(for: host),
                        tint: tint(for: host),
                        status: status(for: host))
                }
            }
            ForEach(Array(scraped.prefix(2)), id: \.self) { instance in
                nodeColumn(instance)
            }
        }
    }

    private func nodeColumn(_ instance: String) -> some View {
        let stats = homelab.nodes[instance] ?? HomelabManager.NodeStats()
        let width: CGFloat = 168
        return PanelColumn(title: instance.uppercased(), width: width) {
            PanelRow(label: Caption.cpu, value: HomelabManager.percent(stats.cpu))
            MeterBar(fraction: stats.cpu ?? 0, width: width)
            PanelRow(label: Caption.memory, value: HomelabManager.percent(stats.memory))
            MeterBar(fraction: stats.memory ?? 0, width: width)
            PanelRow(label: Caption.load, value: loadText(stats.load1))
            PanelRow(label: Caption.root, value: HomelabManager.percent(stats.rootUsed))
            MeterBar(fraction: stats.rootUsed ?? 0, width: width)
        }
    }

    // MARK: - Per-guest readings

    private func status(for host: String) -> PanelStatus {
        if let up = homelab.nodes[host]?.up { return up ? .up : .down }
        guard case .ok = homelab.loki else { return .unknown }
        guard let log = homelab.hosts[host] else { return .unknown }
        if log.critical > 0 { return .warn }
        return log.lines > 0 ? .up : .down
    }

    /// Alerts if there are any, because that is the reason to look; otherwise the evidence
    /// the box is alive — a load figure for the scraped hosts, a line count for the rest.
    private func summary(for host: String) -> String {
        let log = homelab.hosts[host] ?? HomelabManager.HostLog()
        if log.critical > 0 || log.warning > 0 {
            return "\(log.critical)C \(log.warning)W"
        }
        if let cpu = homelab.nodes[host]?.cpu {
            return HomelabManager.percent(cpu)
        }
        if log.lines > 0 { return "\(log.lines) ln · \(Caption.clear)" }
        return Caption.quiet
    }

    private func tint(for host: String) -> Color? {
        let log = homelab.hosts[host] ?? HomelabManager.HostLog()
        if log.critical > 0 { return StatsPalette.critical }
        if log.warning > 0 { return StatsPalette.serious }
        return nil
    }

    private func loadText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
    }
}
