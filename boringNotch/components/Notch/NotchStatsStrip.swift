//
//  NotchStatsStrip.swift
//  boringNotch
//
//  The bottom row of the expanded notch: API usage, then system load.
//

import Defaults
import SwiftUI

// MARK: - Palette

/// Load severity, deliberately short of a full traffic-light ramp.
///
/// There is no "good" green. A readout that turns green to say nothing is wrong is noise —
/// the value is already right there, and colour that is always on stops meaning anything.
/// Normal sits in the user's own accent, and the semantic steps appear only when the number
/// actually warrants a look. Colour is never the sole channel: every cell has a text label
/// and the figure itself.
private enum StatsPalette {
    static let serious = Color(red: 0.925, green: 0.514, blue: 0.353)   // #ec835a
    static let critical = Color(red: 0.816, green: 0.231, blue: 0.231)  // #d03b3b

    /// Both steps clear 3:1 on black and separate by ΔE 11.3 under deuteranopia, checked
    /// against this surface rather than assumed.
    static func severity(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: .effectiveAccent
        case ..<0.90: serious
        default: critical
        }
    }
}

// MARK: - Sparkline

/// A filled trace, shaped the way the system's own small graphs are — a soft gradient area
/// under a thin line, rather than the bare polyline a dashboard library would draw.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }

            let step = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let clamped = min(max(values[index], 0), 1)
                // A little headroom so a trace pinned at 100% still reads as a line
                // rather than merging with the top edge.
                return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - clamped * 0.9) - 0.5)
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count { line.addLine(to: point(index)) }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.42), color.opacity(0.04)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))

            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 9)
        .accessibilityHidden(true)
    }
}

// MARK: - Strip

/// One `statsStripHeight` row, attached as a bottom safe-area inset so it reserves exactly
/// that much and no more. The notch grows by the same amount when the strip is enabled —
/// see `openNotchSize`, which records why fitting it inside the existing 190 pt did not work.
///
/// Laid out as gauge cells rather than a bar of chips: a small uppercase label over the
/// figure, with the trace beside it. The hierarchy is the point — a row where the label and
/// the value carry identical weight reads as chrome, and the number is the thing being read.
struct NotchStatsStrip: View {
    @ObservedObject private var stats = SystemStatsManager.shared
    @ObservedObject private var usage = RouterUsageManager.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    @ObservedObject private var bluetooth = BluetoothBatteryManager.shared

    @Default(.statsStripShowUsage) private var showUsage
    @Default(.statsStripShowSystem) private var showSystem
    @Default(.statsStripShowBattery) private var showBattery
    @Default(.statsStripShowCPU) private var showCPU
    @Default(.statsStripShowMemory) private var showMemory
    @Default(.statsStripShowNetwork) private var showNetwork
    @Default(.statsStripSparklines) private var showSparklines
    @Default(.statsStripColor) private var useColor

    /// The notch springs open in ~0.42 s. Rendering the row at full strength from the first
    /// frame makes it read as pasted on. It settles in just behind the expansion instead.
    @State private var settled = false

    /// Grouped by subject rather than by which manager the numbers came from. `system`
    /// used to carry battery, CPU, memory and both network figures -- three unrelated
    /// questions sharing a row because they arrived together.
    private enum Page: Hashable { case usage, limits, power, system, network }

    @State private var pageIndex = 0
    @State private var isHeld = false
    @State private var flipTimer: Timer?

    @Default(.statsStripFlipInterval) private var flipInterval

    private var pages: [Page] {
        var pages: [Page] = []
        if showUsage {
            pages.append(.usage)
            if usage.limits != nil { pages.append(.limits) }
        }
        if showSystem {
            // A page has to earn its slot. Six pages at the current flip interval is most
            // of a minute for a full cycle, so a page with nothing to say is not a page --
            // the same rule the usage pages above already follow.
            if showBattery || !bluetooth.devices.isEmpty { pages.append(.power) }
            if showCPU || showMemory { pages.append(.system) }
            if showNetwork { pages.append(.network) }
        }
        return pages
    }

    private var currentPage: Page? {
        guard !pages.isEmpty else { return nil }
        return pages[min(pageIndex, pages.count - 1) % pages.count]
    }

    private func advance() {
        guard pages.count > 1 else { return }
        // Snappy and short. A split-flap board goes clack; a 0.42s eased slide reads as
        // the row being dragged rather than flipped.
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            pageIndex = (pageIndex + 1) % pages.count
        }
    }

    /// Same discipline as every other timer here: stored, guarded, invalidated on the way
    /// out. A closed notch flips nothing.
    private func startFlipping() {
        stopFlipping()
        guard pages.count > 1, flipInterval > 0 else { return }

        let timer = Timer(timeInterval: flipInterval, repeats: true) { _ in
            Task { @MainActor in
                guard !isHeld else { return }
                advance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flipTimer = timer
    }

    private func stopFlipping() {
        flipTimer?.invalidate()
        flipTimer = nil
    }

    var body: some View {
        ZStack {
            switch currentPage {
            // One page, not two. The totals and the split answer the same question, and
            // separating them meant waiting a whole flip to find out who spent it.
            case .usage: row { caption("TOKENS USED"); usageCells }
            case .limits: row { caption("PLAN LIMITS"); limitCells }
            case .power: row { caption("POWER"); powerCells }
            case .system: row { caption("SYSTEM"); systemCells }
            case .network: row { caption("NETWORK"); networkCells }
            case .none: Color.clear
            }
        }
        // Keyed on the page so SwiftUI treats a flip as a swap rather than a redraw.
        .id(currentPage)
        .transition(
            .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)))
        .frame(height: statsStripRowHeight)
        .clipped()
        // Clears the player badge hanging off the album art's corner.
        .padding(.top, statsStripTopGap)
        .contentShape(Rectangle())
        // Hovering holds the current page — nothing is more annoying than a number
        // flipping away while it is being read. Clicking advances by hand.
        .onHover { hovering in
            isHeld = hovering
        }
        .onTapGesture { advance() }
        .opacity(settled ? 1 : 0)
        .offset(y: settled ? 0 : 7)
        .onAppear {
            stats.start()
            bluetooth.start()
            usage.refresh()
            startFlipping()
            withAnimation(.smooth(duration: 0.3).delay(0.14)) { settled = true }
        }
        .onDisappear {
            settled = false
            stopFlipping()
            // Sampling exists only while this row does. A closed notch costs nothing --
            // no CPU sampling, and no Bluetooth radio work either.
            stats.stop()
            bluetooth.stop()
        }
    }

    /// Matches the open notch's own bottom corners, so the scrim ends where the panel
    /// ends rather than cutting across it.
    private var bottomCornerRadius: CGFloat {
        Defaults[.cornerRadiusScaling]
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private func row<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ScrollView(.horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    content()
                }
                .padding(.horizontal, 8)
                // Centred while the row fits, and scrolling from the left once it does
                // not. Left-aligning read as accidental under a player whose own content
                // spans the full width.
                .frame(minWidth: width, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .mask(fade(width: width))
        }
    }

    /// Names what the row is counting. Without it a page reading ANTHROPIC 5.8M /
    /// OPENROUTER 293K says who but never what or over how long, which is exactly the
    /// question it left people asking.
    @ViewBuilder
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold))
            .tracking(0.7)
            // Was .tertiary at 70%, which is about 25% white — invisible over anything
            // that is not flat black.
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize()
        Divider().frame(height: 10)
    }

    /// Softens the ends so an overflowing row reads as continuing rather than as cut off.
    /// Measured in points, not fractions: the first version faded 3% of the width per side,
    /// which at 640 pt is a 19 pt wash sitting on top of the leading cell and dimming it
    /// permanently.
    private func fade(width: CGFloat) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 3 / width),
                .init(color: .black, location: 1 - 18 / width),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing)
    }

    // MARK: Cells

    @ViewBuilder
    private var usageCells: some View {
        if usage.isAvailable {
            let windows = Self.distinctWindows(usage)
            let providers = usage.byUpstream(for: .week)
                // A provider at zero spends a full cell to say nothing.
                .filter { $0.value.billedTokens > 0 }
                .sorted { $0.value.billedTokens > $1.value.billedTokens }
            let reserve = Self.tokenWidth(
                across: windows.map { usage.totals(for: $0).billedTokens }
                    + [usage.totals(for: .all).cachedTokens]
                    + providers.map { $0.value.billedTokens })

            // Billed tokens, not the total. Cache reads outweigh real work by two orders of
            // magnitude on a normal day, so folding them in would read as enormous usage
            // every single day and mean nothing; cache gets its own cell.
            ForEach(windows, id: \.self) { window in
                gauge(window.label, Self.compact(usage.totals(for: window).billedTokens),
                      widest: reserve)
            }
            gauge("CACHED", Self.compact(usage.totals(for: .all).cachedTokens), widest: reserve)
            let spend = usage.totals(for: .all).cost
            if spend > 0 {
                gauge("SPENT", String(format: "$%.2f", spend), widest: "$99.99")
            }
            if !providers.isEmpty {
                // A rule rather than a second caption. "ANTHROPIC" next to "ALL TIME" needs
                // separating, but a caption costs its own text width on a row that has none
                // to spare -- and a provider's name already says what it is.
                Divider().frame(height: 10)
                ForEach(providers, id: \.key) { entry in
                    gauge(entry.key.uppercased(), Self.compact(entry.value.billedTokens),
                          widest: reserve)
                }
            }
        } else if usage.needsAuthorization {
            // The sandbox, not a missing file. Settings has the button that fixes it.
            gauge("API USAGE", "Grant access", widest: "Grant access", tint: StatsPalette.serious)
        } else {
            gauge("API USAGE", "No log", widest: "Grant access")
        }
    }

    /// Windows that carry distinct figures.
    ///
    /// `UsageWindow.allCases` is four cells, and early in a month TODAY, WEEK, MONTH and
    /// ALL TIME routinely carry two distinct numbers between them. Printing a figure twice
    /// under two labels is worse than not printing it: it reads as a coincidence the user
    /// has to stop and check.
    private static func distinctWindows(_ usage: RouterUsageManager) -> [UsageWindow] {
        var seen = Set<Int>()
        return UsageWindow.allCases.filter { seen.insert(usage.totals(for: $0).billedTokens).inserted }
    }

    /// The width every token cell reserves, sized to the largest figure *actually on this
    /// row* rather than to the largest one imaginable.
    ///
    /// This is what pushed the merged page past the edge. `widest:` exists so a cell does not
    /// shove its neighbours as its value grows, but hard-coding `"999.9M"` reserved room for
    /// a hundred million tokens in every cell -- about a character and a half of dead space,
    /// nine times over, on a row whose biggest number was 31.5M.
    private static func tokenWidth(across values: [Int]) -> String {
        let template = compact(values.max() ?? 0)
        // Same shape, every digit at its widest, so the reservation still cannot be
        // outgrown by a value of the same magnitude.
        return String(template.map { $0.isNumber ? "9" : $0 })
    }

    /// The subscription's own meters. These are quota, not money, which is why they cannot
    /// come from the request log — the proxy sees tokens, not the plan. The statusline
    /// publishes them beside the log from the JSON Claude Code hands it.
    @ViewBuilder
    private var limitCells: some View {
        if let limits = usage.limits {
            gauge("5 HOUR", "\(Int(limits.fiveHourPercent.rounded()))%", widest: "100%",
                  tint: StatsPalette.severity(limits.fiveHourPercent / 100),
                  alarming: limits.fiveHourPercent >= 90)
            gauge("RESETS IN", Self.countdown(to: limits.fiveHourResetsAt), widest: "23h 59m")
            gauge("7 DAY", "\(Int(limits.sevenDayPercent.rounded()))%", widest: "100%",
                  tint: StatsPalette.severity(limits.sevenDayPercent / 100),
                  alarming: limits.sevenDayPercent >= 90)
            gauge("RESETS IN", Self.countdown(to: limits.sevenDayResetsAt), widest: "23h 59m")
        }
    }

    /// This Mac's battery, then every Bluetooth device that reports one.
    @ViewBuilder
    private var powerCells: some View {
        if showBattery {
            // Severity runs the other way here: a battery is worrying when it is low, so
            // the fraction is inverted before it hits the same ramp.
            gauge(battery.isCharging ? "CHARGING" : "BATTERY",
                  "\(Int((battery.levelBattery).rounded()))%",
                  widest: "100%",
                  tint: battery.isCharging
                      ? .effectiveAccent
                      : StatsPalette.severity(1 - Double(battery.levelBattery) / 100),
                  trend: stats.batteryHistory,
                  alarming: !battery.isCharging && battery.levelBattery <= 10)
        }
        // Which way the power is actually flowing, and how hard. The percentage says how
        // much is left; this says what is happening to it right now -- and it is the number
        // that answers "what is draining my battery" while the percentage is still 90%.
        if stats.batteryWatts != 0 {
            let charging = stats.batteryWatts > 0
            // One label, and the sign carries the direction. It was `POWER IN` / `POWER OUT`,
            // which meant the cell renamed itself depending on whether a cable was plugged in
            // -- and "where is POWER IN" is the reasonable question that gets you, because a
            // label that only exists half the time reads as a missing feature rather than as
            // a state. `-13.3 W` and `+45.0 W` are the same cell saying two things.
            gauge("POWER",
                  String(format: "%+.1f W", stats.batteryWatts),
                  widest: "-99.9 W",
                  tint: charging ? .effectiveAccent : StatsPalette.severity(abs(stats.batteryWatts) / 40),
                  trend: stats.powerHistory,
                  alarming: !charging && abs(stats.batteryWatts) >= 35)
        }
        // Two sides to this page: this Mac, then everything else, split by a rule. They are
        // the same question asked of different hardware, and they do not belong in one
        // undifferentiated run of cells.
        if !bluetooth.devices.isEmpty {
            Divider().frame(height: 10)
        }
        // One gauge per device, named by the device, with the same sparkline everything
        // else on the row carries. It is polled once a minute rather than once a second, so
        // it fills in over a session instead of arriving complete -- which is honest for a
        // quantity that moves that slowly.
        ForEach(bluetooth.devices) { device in
            gauge(device.name.uppercased(),
                  "\(device.percent)%",
                  widest: "100%",
                  tint: StatsPalette.severity(1 - Double(device.percent) / 100),
                  trend: device.history,
                  alarming: device.percent <= 10)
            // The equivalent of POWER OUT for something that will not tell us its wattage.
            // Appears once it has been watched long enough to be a measurement rather than
            // a rounding artefact.
            if let rate = device.drainPerHour {
                gauge("RATE", String(format: "%+.1f %%/h", rate),
                      widest: "+99.9 %/h",
                      tint: rate < 0 ? StatsPalette.severity(min(abs(rate) / 20, 1)) : .effectiveAccent)
            }
        }
    }

    @ViewBuilder
    private var systemCells: some View {
        if showCPU {
            gauge("CPU", "\(Int((stats.cpuUsage * 100).rounded()))%",
                  widest: "100%",
                  tint: StatsPalette.severity(stats.cpuUsage),
                  trend: stats.cpuHistory,
                  alarming: stats.cpuUsage >= 0.9)
        }
        if showMemory {
            gauge("MEMORY", Self.gigabytes(stats.memoryUsedBytes),
                  widest: "99.9 GB",
                  tint: StatsPalette.severity(stats.memoryFraction),
                  trend: stats.memoryHistory,
                  alarming: stats.memoryFraction >= 0.9)
        }
        // Swap before disk: it is the one that moves minute to minute, and the one that
        // explains a machine that feels slow while CPU and memory both look fine.
        if stats.swapTotalBytes > 0 {
            gauge("SWAP", Self.gigabytes(stats.swapUsedBytes),
                  widest: "99.9 GB",
                  tint: StatsPalette.severity(stats.swapFraction),
                  trend: stats.swapHistory,
                  alarming: stats.swapFraction >= 0.5)
        }
        if stats.diskTotalBytes > 0 {
            gauge("DISK FREE", Self.gigabytes(UInt64(max(stats.diskFreeBytes, 0))),
                  widest: "999.9 GB",
                  tint: StatsPalette.severity(stats.diskFraction),
                  trend: stats.diskHistory,
                  alarming: stats.diskFraction >= 0.9)
        }
        // Only when it has something to say. A cell that permanently reads OK is a cell
        // spent on nothing.
        if stats.thermalState != .nominal {
            gauge("THERMAL", Self.thermalLabel(stats.thermalState),
                  widest: "CRITICAL",
                  tint: StatsPalette.severity(stats.thermalState == .critical ? 1 : 0.8),
                  alarming: stats.thermalState == .critical)
        }
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "OK"
        case .fair: "FAIR"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "—"
        }
    }

    @ViewBuilder
    private var networkCells: some View {
        if showNetwork {
            gauge("DOWN", Self.rate(stats.networkDownBytesPerSec), widest: "999 KB/s",
                  trend: stats.networkDownHistory)
            gauge("UP", Self.rate(stats.networkUpBytesPerSec), widest: "999 KB/s",
                  trend: stats.networkUpHistory)
        }
    }

    // Sized to sit under the player, not to compete with it. At 12 pt semibold the row
    // read as a second headline; the song title itself is only .headline. A footer should
    // be the quietest thing in the notch while still being legible at a glance.
    private static let valueFont = Font.system(size: 10, weight: .medium, design: .rounded)
        .monospacedDigit()

    /// - Parameter widest: the longest string this cell can ever display. The cell reserves
    ///   that width up front, so a figure going from `9 KB/s` to `912 KB/s` does not shove
    ///   every cell to its right along the row. Monospaced digits alone are not enough —
    ///   they fix the width of a digit, not the number of digits or the length of a unit.
    private func gauge(
        _ label: String,
        _ value: String,
        widest: String,
        tint: Color? = nil,
        trend: [Double]? = nil,
        alarming: Bool = false
    ) -> some View {
        let accent = useColor ? (tint ?? .effectiveAccent) : .secondary

        return VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 6.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 4) {
                Text(widest)
                    .font(Self.valueFont)
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(value)
                            .font(Self.valueFont)
                            .foregroundStyle(
                                useColor && alarming
                                    ? AnyShapeStyle(accent)
                                    : AnyShapeStyle(Color.white.opacity(0.92)))
                            // Rolls the digits over rather than swapping them.
                            .contentTransition(.numericText())
                            .animation(.smooth(duration: 0.35), value: value)
                            .fixedSize()
                    }

                // Rendered as soon as the cell has any trace at all, even before there
                // are two samples to join. Gating on trend.count > 1 meant the plot
                // appeared a second after the notch opened and pushed every figure to its
                // right along the row — the graph loading was itself the jolt.
                if showSparklines, let trend {
                    Sparkline(values: trend, color: accent)
                        .animation(.smooth(duration: 0.35), value: trend)
                }
            }
        }
        .fixedSize()
    }

    // MARK: Formatting

    private static func compact(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }

    private static func countdown(to date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds >= 86_400 {
            return "\(Int(seconds / 86_400))d \(Int((seconds.truncatingRemainder(dividingBy: 86_400)) / 3_600))h"
        }
        if seconds >= 3_600 {
            return "\(Int(seconds / 3_600))h \(Int((seconds.truncatingRemainder(dividingBy: 3_600)) / 60))m"
        }
        return "\(Int(seconds / 60))m"
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1_048_576...: String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        case 1_024...: String(format: "%.0f KB/s", bytesPerSecond / 1_024)
        default: "0 KB/s"
        }
    }
}
