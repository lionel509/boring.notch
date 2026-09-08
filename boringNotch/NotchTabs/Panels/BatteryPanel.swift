//
//  BatteryPanel.swift
//  boringNotch
//
//  This Mac's battery, then everything else that reports one.
//

import SwiftUI

/// Charge, flow, trace, and the Bluetooth devices — four columns answering "how much is
/// left", "what is happening to it", "what has been happening to it", and "what else is
/// running low".
///
/// The Bluetooth column keeps its slot even with nothing in it. A column that vanishes when
/// a mouse disconnects re-flows the other three, and a panel whose layout depends on what is
/// paired is a panel you cannot glance at.
struct BatteryPanel: View {
    @ObservedObject private var stats = SystemStatsManager.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    @ObservedObject private var bluetooth = BluetoothBatteryManager.shared

    // 136 + 136 + 126 + 146 + 3 gaps of 10 = 574, kept under the 578 the host gives us so
    // a long device name can never push the last column off the edge.
    private static let gap: CGFloat = 10
    private static let narrow: CGFloat = 136
    private static let trace: CGFloat = 126
    private static let wide: CGFloat = 146

    private var level: Double { min(max(Double(battery.levelBattery), 0), 100) }

    /// A Studio or a mini reports no power source at all, and three columns of zeroes would
    /// read as a broken panel rather than as a desk machine. The Bluetooth column still has
    /// something to say there, so only the Mac's own half collapses.
    private var hasInternalBattery: Bool {
        battery.maxCapacity > 0 || battery.levelBattery > 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            if hasInternalBattery {
                charge
                flow
                history
            } else {
                PanelColumn(
                    title: "BATTERY",
                    width: Self.narrow * 2 + Self.trace + Self.gap * 2
                ) {
                    PanelState(kind: .empty, message: Self.noBatteryMessage)
                }
            }
            devices
        }
    }

    private static let noBatteryMessage = "This Mac runs on mains power"

    // MARK: - Columns

    private var charge: some View {
        PanelColumn(title: "BATTERY", width: Self.narrow) {
            // Severity runs the other way here: a battery is worrying when it is low, so the
            // fraction is inverted before it hits the same ramp every other readout uses.
            StatCell(
                label: "CHARGE",
                value: "\(Int(level.rounded()))%",
                widest: "100%",
                tint: StatsPalette.severity(1 - level / 100),
                alarming: !battery.isCharging && level <= 10)
            MeterBar(
                fraction: level / 100,
                tint: battery.isCharging ? .effectiveAccent : StatsPalette.severity(1 - level / 100),
                width: Self.narrow)
            // `statusText` is read straight off AppleSmartBattery rather than assembled from
            // the event flags, so it is a whole state ahead of anything derived here.
            PanelRow(label: "State", value: battery.statusText)
            PanelRow(label: "Adapter", value: battery.isPluggedIn ? "Connected" : "None")
            PanelRow(label: "Low power", value: battery.isInLowPowerMode ? "On" : "Off")
        }
    }

    private var flow: some View {
        let charging = stats.batteryWatts > 0
        let load = min(abs(stats.batteryWatts) / 40, 1)

        return PanelColumn(title: "FLOW", width: Self.narrow) {
            StatCell(
                label: "NOW",
                value: Self.watts(stats.batteryWatts),
                widest: "↓ 99.9 W",
                tint: charging ? .effectiveAccent : StatsPalette.severity(load),
                trend: stats.powerHistory,
                alarming: !charging && abs(stats.batteryWatts) >= 35)
            PanelRow(label: "Rate", value: Self.rate(ratePerHour))
            PanelRow(
                label: battery.isCharging ? "To full" : "Remaining",
                value: timeRemaining)
            PanelRow(label: "Direction", value: Self.direction(stats.batteryWatts))
        }
    }

    /// A point a minute, persisted, so it survives the notch closing. That is also why it is
    /// drawn wide rather than as an inline sparkline — twenty-four samples squeezed into
    /// 22 pt is a smudge, and the shape is the whole reason to keep the trace.
    private var history: some View {
        PanelColumn(title: "RECENT", width: Self.trace) {
            if stats.batteryHistory.count > 1 {
                Sparkline(
                    values: stats.batteryHistory,
                    color: .effectiveAccent,
                    size: .init(width: Self.trace, height: 30))
                PanelRow(label: "Change", value: Self.change(stats.batteryHistory))
                PanelRow(label: "Low", value: Self.percent(stats.batteryHistory.min()))
                PanelRow(label: "High", value: Self.percent(stats.batteryHistory.max()))
            } else {
                PanelState(kind: .probing, message: Self.collectingMessage)
            }
        }
    }

    private static let collectingMessage = "Collecting samples"
    private static let noDevicesMessage = "Nothing paired reports a level"
    private static let bluetoothOffMessage = "Bluetooth unavailable"

    private var devices: some View {
        PanelColumn(title: "BLUETOOTH", width: Self.wide) {
            if !bluetooth.isAvailable {
                PanelState(kind: .empty, message: Self.bluetoothOffMessage)
            } else if bluetooth.devices.isEmpty {
                PanelState(kind: .probing, message: Self.noDevicesMessage)
            } else {
                // Four rows is the column's height budget. The overflow row is not a
                // truncation apology — it is the count, which is the only thing the rows it
                // replaced would have added.
                ForEach(bluetooth.devices.prefix(4)) { device in
                    PanelRow(
                        label: device.name,
                        value: "\(device.percent)%",
                        tint: Self.lowTint(Double(device.percent)),
                        status: device.percent <= 10 ? .down : nil)
                }
                if bluetooth.devices.count > 4 {
                    PanelRow(
                        label: "More paired",
                        value: "\(bluetooth.devices.count - 4)")
                }
            }
        }
    }

    // MARK: - Derived figures

    /// Percentage points per hour, measured off the trace rather than estimated from watts.
    ///
    /// There is no capacity in watt-hours published anywhere here, so watts cannot be turned
    /// into a rate — but the trace is one integer reading a minute, and over ten of them the
    /// slope is a measurement rather than a rounding artefact. `nil` until then, and `nil`
    /// when the charge has not actually moved.
    private var ratePerHour: Double? {
        let history = stats.batteryHistory
        guard history.count >= 10, let first = history.first, let last = history.last
        else { return nil }
        let hours = Double(history.count - 1) / 60
        let delta = (last - first) * 100
        guard hours > 0, abs(delta) >= 1 else { return nil }
        return delta / hours
    }

    private var timeRemaining: String {
        if battery.isCharging {
            return Self.duration(minutes: battery.timeToFullCharge)
        }
        guard let rate = ratePerHour, rate < 0 else { return "—" }
        return Self.duration(minutes: Int((level / abs(rate) * 60).rounded()))
    }

    // MARK: - Formatting

    private static func watts(_ value: Double) -> String {
        guard abs(value) >= 0.05 else { return "0.0 W" }
        return String(format: "%@ %.1f W", value > 0 ? "↑" : "↓", abs(value))
    }

    private static func direction(_ value: Double) -> String {
        if value > 0.05 { return "Charging" }
        if value < -0.05 { return "Draining" }
        return "Idle"
    }

    private static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.1f %%/h", value)
    }

    private static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    private static func change(_ history: [Double]) -> String {
        guard let first = history.first, let last = history.last else { return "—" }
        return String(format: "%+d%%", Int(((last - first) * 100).rounded()))
    }

    private static func duration(minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    private static func lowTint(_ percent: Double) -> Color? {
        let severity = 1 - min(max(percent, 0), 100) / 100
        return severity >= 0.75 ? StatsPalette.severity(severity) : nil
    }
}
