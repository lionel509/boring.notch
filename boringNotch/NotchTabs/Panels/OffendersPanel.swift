//
//  OffendersPanel.swift
//  boringNotch
//
//  Which processes are actually spending the machine.
//

import SwiftUI

/// One process, as the helper reports it.
///
/// Deliberately a plain value type owned by this file rather than a manager. The app is
/// sandboxed and `proc_listpids` / `ps` return nothing from inside the container — no error,
/// no partial list, just zero rows — so there is nothing for a manager to poll here. The
/// list can only arrive over XPC from the privileged helper, and until it does this panel's
/// job is to hold a designed empty state rather than to keep asking.
struct ProcessRow: Identifiable {
    /// The executable's name as the helper reports it, without its path.
    let name: String
    /// Percent of one core, the way `ps` counts it — so it runs past 100 on a process using
    /// more than one core, and the column reserves room for three digits.
    let cpu: Double
    let memBytes: UInt64

    var id: String { name }
}

struct OffendersPanel: View {
    @ObservedObject private var stats = SystemStatsManager.shared

    /// Filled by the host's XPC fetch. Held here rather than in a manager for the reason
    /// `ProcessRow` records.
    @State private var rows: [ProcessRow] = []
    /// Set when the helper answered and the answer was a refusal — a missing helper is a
    /// different state from a helper that has not replied yet, and they must not look alike.
    @State private var failure: String?

    // 3 x 182 + 2 x 10 = 566, kept a little under the 578 the host gives us so a
    // wider label can never push the last column off the edge.
    private static let column: CGFloat = 182
    private static let gap: CGFloat = 10
    private static let rowLimit = 4

    private static let probingMessage = "Asking the helper for the process list"

    var body: some View {
        content
            // `.task` rather than `.onAppear` + a stored Timer: it is cancelled automatically
            // when the deck flips this panel away, which is exactly the battery rule and
            // leaves no timer to forget. The helper sleeps 0.3 s between its two readings, so
            // three seconds is as fast as this is worth asking.
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            PanelState(kind: .failed, message: failure)
        } else if rows.isEmpty {
            PanelState(kind: .probing, message: Self.probingMessage)
        } else {
            HStack(alignment: .top, spacing: Self.gap) {
                byCPU
                byMemory
                summary
            }
        }
    }

    // MARK: - Fetch

    /// The app is sandboxed and gets nothing from `proc_listpids`, so the ranking is measured
    /// in the XPC helper — which is not sandboxed — and arrives as JSON.
    private func load() async {
        let json = await XPCHelperClient.shared.topProcesses(limit: Self.fetchLimit)
        guard let data = json?.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            failure = Self.unreachable
            return
        }
        failure = nil
        rows = raw.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return ProcessRow(
                name: name,
                // The helper reports a fraction of one core; this column counts the way `ps`
                // does, so a process on two cores reads 200.
                cpu: (entry["cpu"] as? Double ?? 0) * 100,
                memBytes: (entry["mem"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    private static let fetchLimit = 8
    private static let unreachable = "Helper unreachable"


    // MARK: - Columns

    private var byCPU: some View {
        let ranked = rows.sorted { $0.cpu > $1.cpu }

        return PanelColumn(title: "TOP BY CPU", width: Self.column) {
            ForEach(ranked.prefix(Self.rowLimit)) { row in
                PanelRow(label: row.name, value: Self.cpu(row.cpu), tint: Self.cpuTint(row.cpu))
            }
        }
    }

    private var byMemory: some View {
        let ranked = rows.sorted { $0.memBytes > $1.memBytes }
        let installed = Double(stats.memoryTotalBytes)

        return PanelColumn(title: "TOP BY MEMORY", width: Self.column) {
            ForEach(ranked.prefix(Self.rowLimit)) { row in
                PanelRow(
                    label: row.name,
                    value: Units.bytes(row.memBytes),
                    tint: Self.memoryTint(Double(row.memBytes), installed: installed))
            }
        }
    }

    /// What the list adds up to, against what the kernel says the whole machine is doing.
    ///
    /// This is the column that makes the other two trustworthy: a per-process list that does
    /// not roughly reconcile with the aggregate counters is a list that is missing something,
    /// and the reader can see that here rather than being misled by a plausible-looking top
    /// four.
    private var summary: some View {
        let listedCPU = rows.reduce(0) { $0 + $1.cpu }
        let listedMemory = rows.reduce(UInt64(0)) { $0 + $1.memBytes }

        return PanelColumn(title: "AGAINST THE MACHINE", width: Self.column) {
            StatCell(
                label: "SYSTEM CPU",
                value: Self.percent(stats.cpuUsage),
                widest: "100%",
                tint: StatsPalette.severity(stats.cpuUsage),
                trend: stats.cpuHistory,
                alarming: stats.cpuUsage >= 0.9)
            MeterBar(fraction: stats.cpuUsage, width: Self.column)
            PanelRow(label: "Processes listed", value: "\(rows.count)")
            PanelRow(label: "Their CPU", value: Self.cpu(listedCPU))
            PanelRow(label: "Their memory", value: Units.bytes(listedMemory))
            PanelRow(label: "System memory", value: Units.bytes(stats.memoryUsedBytes))
        }
    }

    // MARK: - Formatting

    /// Three digits and no decimal. A process's CPU share moves every sample, so a tenth is
    /// a character that changes constantly and settles nothing.
    private static func cpu(_ value: Double) -> String {
        "\(Int(max(value, 0).rounded()))%"
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// Measured against the hardware, not against the row above it.
    ///
    /// Ranking the colour by position would paint the top row every time, including on an
    /// idle machine where the busiest process is at 2% — the tint would then mean "first",
    /// which the ordering already says. A full core is the first figure worth a second look,
    /// two cores the first worth interrupting for.
    private static func cpuTint(_ percentOfCore: Double) -> Color? {
        switch percentOfCore {
        case 200...: return StatsPalette.critical
        case 100...: return StatsPalette.serious
        default: return nil
        }
    }

    /// Same rule in the other unit: a quarter of installed memory in one process is the
    /// point at which everything else starts paging.
    private static func memoryTint(_ bytes: Double, installed: Double) -> Color? {
        guard installed > 0 else { return nil }
        switch bytes / installed {
        case 0.25...: return StatsPalette.critical
        case 0.10...: return StatsPalette.serious
        default: return nil
        }
    }
}
