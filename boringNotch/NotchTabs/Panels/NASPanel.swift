//
//  NASPanel.swift
//  boringNotch
//
//  The Synology, once it is scraped and shipping logs like everything else.
//

import Defaults
import SwiftUI

/// The label the NAS is expected to appear under — `instance` in Prometheus, `host` in Loki.
/// One constant, at the top, because it is the single thing that has to change when the
/// exporter is finally wired up under a different name.
enum NASHost {
    /// Read from settings rather than compiled in: the label is chosen when the exporter and
    /// log shipper are set up, not when this is built. Both Prometheus (`instance`) and Loki
    /// (`host`) must use the same value, or the NAS shows up as two separate rows.
    static var label: String {
        let set = Defaults[.homelabNASHost].trimmingCharacters(in: .whitespacesAndNewlines)
        return set.isEmpty ? "synology" : set
    }
}

private enum Caption {
    static let cpu = "CPU"
    static let memory = "MEM"
    static let load = "LOAD 1m"
    static let used = "USED"
    static let free = "FREE"
    static let capacity = "CAPACITY"
    static let volumes = "VOLUMES"
    static let health = "HEALTH"
    static let logs = "LOGS"
    static let exporter = "node_exporter"
    static let shipper = "log shipper"
    static let expected = "expected as"
    static var critical: String { "CRITICAL \(HomelabManager.alertWindowHours)h" }
    static var warning: String { "WARN \(HomelabManager.alertWindowHours)h" }
    static let notScraped = "not scraped"
    static let notShipping = "no lines"
    static let probing = "Looking for the NAS…"
    static var lines: String { "LINES \(HomelabManager.livenessWindowMinutes)m" }
}

/// Built against the same Prometheus and Loki as the rest of the fleet, because that is
/// where the NAS is being wired. Until it shows up, every column names the specific thing
/// that is missing — a wall of dashes would look like a broken panel rather than an
/// unfinished one.
struct NASPanel: View {
    @ObservedObject private var homelab = HomelabManager.shared

    private var stats: HomelabManager.NodeStats? { homelab.nodes[NASHost.label] }
    private var log: HomelabManager.HostLog? { homelab.hosts[NASHost.label] }
    private var hasAnything: Bool { stats != nil || log != nil }

    var body: some View {
        Group {
            if !hasAnything, let problem = homelab.sourceProblem {
                PanelState(kind: problem.failed ? .failed : .empty, message: problem.message)
            } else if !hasAnything, !homelab.nodesLoaded {
                PanelState(kind: .probing, message: Caption.probing)
            } else {
                content
            }
        }
        .onAppear { homelab.start(.nodes) }
        .onDisappear { homelab.stop(.nodes) }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            capacityColumn
            healthColumn
            logColumn
        }
    }

    private var capacityColumn: some View {
        let width: CGFloat = 190
        let size = stats?.volumeSize ?? 0
        let avail = stats?.volumeAvail ?? 0
        return PanelColumn(title: Caption.capacity, width: width) {
            if size > 0 {
                let used = 1 - avail / size
                PanelRow(label: Caption.volumes, value: HomelabManager.percent(used))
                MeterBar(fraction: used, width: width)
                PanelRow(label: Caption.used, value: HomelabManager.bytes(size - avail))
                PanelRow(label: Caption.free, value: HomelabManager.bytes(avail))
            } else {
                PanelRow(label: Caption.exporter, value: Caption.notScraped, status: .unknown)
                PanelRow(label: Caption.expected, value: NASHost.label)
            }
        }
    }

    private var healthColumn: some View {
        let width: CGFloat = 178
        return PanelColumn(title: Caption.health, width: width) {
            if let stats, stats.cpu != nil || stats.memory != nil {
                PanelRow(label: Caption.cpu, value: HomelabManager.percent(stats.cpu))
                MeterBar(fraction: stats.cpu ?? 0, width: width)
                PanelRow(label: Caption.memory, value: HomelabManager.percent(stats.memory))
                MeterBar(fraction: stats.memory ?? 0, width: width)
                PanelRow(label: Caption.load, value: loadText(stats.load1))
            } else {
                PanelRow(label: Caption.exporter, value: Caption.notScraped, status: .unknown)
                PanelRow(label: Caption.expected, value: NASHost.label)
            }
        }
    }

    private var logColumn: some View {
        let width: CGFloat = 178
        return PanelColumn(title: Caption.logs, width: width) {
            if let log, log.lines > 0 {
                PanelRow(label: Caption.lines, value: "\(log.lines)", status: .up)
                PanelRow(
                    label: Caption.critical, value: "\(log.critical)",
                    tint: log.critical > 0 ? StatsPalette.critical : nil)
                PanelRow(
                    label: Caption.warning, value: "\(log.warning)",
                    tint: log.warning > 0 ? StatsPalette.serious : nil)
            } else {
                PanelRow(label: Caption.shipper, value: Caption.notShipping, status: .unknown)
                PanelRow(label: Caption.expected, value: NASHost.label)
            }
        }
    }

    private func loadText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value)
    }
}
