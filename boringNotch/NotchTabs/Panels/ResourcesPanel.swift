//
//  ResourcesPanel.swift
//  boringNotch
//
//  The roomy version of the stats strip's SYSTEM page.
//

import SwiftUI

/// Four columns, one subject each: processor, memory, storage, power.
///
/// The strip had to say all of this in a single 24 pt row, so it flipped between pages and
/// dropped whatever did not fit. With 578 x 150 the whole picture fits at once, which is the
/// only reason this panel exists — a scrolling version of the same row would be worse than
/// the row.
struct ResourcesPanel: View {
    @ObservedObject private var stats = SystemStatsManager.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared

    /// 4 x 136 + 3 x 10 = 574, inside the 578 the host gives us with a little slack so a
    /// wider label can never push the last column off the edge.
    private static let column: CGFloat = 136
    private static let gap: CGFloat = 10

    /// Sampling starts when the panel appears, so there is a real moment with no figures at
    /// all. `cpuHistory` gains its first point on the first tick, which makes it the honest
    /// test for "has anything been measured yet".
    private var hasSample: Bool { !stats.cpuHistory.isEmpty }

    var body: some View {
        if hasSample {
            HStack(alignment: .top, spacing: Self.gap) {
                processor
                memory
                storage
                power
            }
        } else {
            PanelState(kind: .probing, message: Self.probingMessage)
        }
    }

    private static let probingMessage = "Reading kernel counters"

    // MARK: - Columns

    private var processor: some View {
        PanelColumn(title: "PROCESSOR", width: Self.column) {
            StatCell(
                label: "IN USE",
                value: Self.percent(stats.cpuUsage),
                widest: "100%",
                tint: StatsPalette.severity(stats.cpuUsage),
                trend: stats.cpuHistory,
                alarming: stats.cpuUsage >= 0.9)
            MeterBar(fraction: stats.cpuUsage, width: Self.column)
            PanelRow(label: "Cores", value: "\(ProcessInfo.processInfo.processorCount)")
            PanelRow(label: "Peak", value: Self.percent(stats.cpuHistory.max() ?? 0))
            PanelRow(label: "Idle", value: Self.percent(1 - stats.cpuUsage))
        }
    }

    private var memory: some View {
        let free = stats.memoryTotalBytes > stats.memoryUsedBytes
            ? stats.memoryTotalBytes - stats.memoryUsedBytes
            : 0

        return PanelColumn(title: "MEMORY", width: Self.column) {
            StatCell(
                label: "IN USE",
                value: Units.bytes(stats.memoryUsedBytes),
                widest: Units.widestBytes,
                tint: StatsPalette.severity(stats.memoryFraction),
                trend: stats.memoryHistory,
                alarming: stats.memoryFraction >= 0.9)
            MeterBar(fraction: stats.memoryFraction, width: Self.column)
            PanelRow(label: "Installed", value: Units.bytes(stats.memoryTotalBytes))
            PanelRow(label: "Available", value: Units.bytes(free))
            // Share of installed memory, not a pressure reading — the kernel's pressure
            // figure is a different measurement and this one must not borrow its name.
            PanelRow(label: "Share", value: Self.percent(stats.memoryFraction))
        }
    }

    /// Swap above disk, because swap is the one that moves minute to minute and the one that
    /// explains a machine feeling slow while CPU and memory both look fine.
    private var storage: some View {
        PanelColumn(title: "STORAGE", width: Self.column) {
            if stats.swapTotalBytes == 0 && stats.diskTotalBytes == 0 {
                PanelState(kind: .empty, message: Self.noVolumeMessage)
            } else {
                if stats.swapTotalBytes > 0 {
                    StatCell(
                        label: "SWAP USED",
                        value: Units.bytes(stats.swapUsedBytes),
                        widest: Units.widestBytes,
                        tint: StatsPalette.severity(stats.swapFraction),
                        trend: stats.swapHistory,
                        alarming: stats.swapFraction >= 0.5)
                    MeterBar(fraction: stats.swapFraction, width: Self.column)
                    PanelRow(label: "Swap size", value: Units.bytes(stats.swapTotalBytes))
                }
                if stats.diskTotalBytes > 0 {
                    StatCell(
                        label: "DISK FREE",
                        value: Units.bytes(UInt64(max(stats.diskFreeBytes, 0))),
                        widest: Units.widestBytes,
                        tint: StatsPalette.severity(stats.diskFraction),
                        trend: stats.diskHistory,
                        alarming: stats.diskFraction >= 0.9)
                    MeterBar(fraction: stats.diskFraction, width: Self.column)
                    PanelRow(
                        label: "Volume",
                        value: Units.bytes(UInt64(max(stats.diskTotalBytes, 0))))
                }
            }
        }
    }

    private static let noVolumeMessage = "No volume reported"

    /// Watts and heat together: they are the same story told from two ends, and the strip
    /// only ever had room for one of them at a time.
    private var power: some View {
        let charging = stats.batteryWatts > 0
        let load = min(abs(stats.batteryWatts) / 40, 1)

        return PanelColumn(title: "POWER", width: Self.column) {
            StatCell(
                label: "FLOW",
                value: Self.flow(stats.batteryWatts),
                widest: "↓ 99.9 W",
                tint: charging ? .effectiveAccent : StatsPalette.severity(load),
                trend: stats.powerHistory,
                alarming: !charging && abs(stats.batteryWatts) >= 35)
            PanelRow(
                label: "Charge",
                value: "\(Int(battery.levelBattery.rounded()))%",
                tint: Self.lowChargeTint(Double(battery.levelBattery)))
            PanelRow(label: "Supply", value: battery.statusText)
            PanelRow(
                label: "Thermal",
                value: Self.thermalLabel(stats.thermalState),
                tint: stats.thermalState == .critical ? StatsPalette.critical : nil,
                status: Self.thermalStatus(stats.thermalState))
            PanelRow(label: "Low power", value: battery.isInLowPowerMode ? "On" : "Off")
        }
    }

    // MARK: - Formatting

    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// One label, and an arrow carries the direction — the same decision the strip's POWER
    /// cell records at length. A signed figure leaves a minus sign sitting in the row all
    /// day, and renaming the cell per state reads as a missing feature rather than a state.
    private static func flow(_ watts: Double) -> String {
        guard abs(watts) >= 0.05 else { return "0.0 W" }
        return String(format: "%@ %.1f W", watts > 0 ? "↑" : "↓", abs(watts))
    }

    private static func lowChargeTint(_ percent: Double) -> Color? {
        let severity = 1 - min(max(percent, 0), 100) / 100
        return severity >= 0.75 ? StatsPalette.severity(severity) : nil
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private static func thermalStatus(_ state: ProcessInfo.ThermalState) -> PanelStatus {
        switch state {
        case .nominal: .up
        case .fair, .serious: .warn
        case .critical: .down
        @unknown default: .unknown
        }
    }
}
