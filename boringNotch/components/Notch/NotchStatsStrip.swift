//
//  NotchStatsStrip.swift
//  boringNotch
//
//  The bottom row of the expanded notch: API usage, then system load.
//

import Defaults
import SwiftUI

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
            // Both subscriptions share one page. Two plans is two facts each, not a
            // subject each, and a page per vendor meant waiting a whole flip to compare
            // them -- the same reason TOKENS USED stopped being two pages.
            if usage.limits != nil || usage.kimiLimits != nil { pages.append(.limits) }
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
            case .usage: usageRow
            case .limits: row { caption("PLAN LIMITS"); limitCells }
            case .power: row { caption("POWER"); powerCells }
            case .system: row { caption("SYSTEM"); systemCells }
            // Captioned by the network itself. An SSID can be long, and a caption is
            // `fixedSize` while a gauge reserves a fixed width -- so the name belongs here,
            // where its length costs nothing, rather than in a cell that would have to
            // reserve room for the longest name imaginable.
            case .network: row { caption(stats.wifiSSID?.uppercased() ?? "NETWORK"); networkCells }
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
        // Same rule as the tab decks: a hand-driven flip buys a full interval, rather than
        // leaving the original schedule to fire a moment later and snatch the row away.
        .onChange(of: pageIndex) { _, _ in startFlipping() }
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

    /// The usage page, fitted to the notch rather than scrolled past it.
    ///
    /// Every upstream Switchboard routes to earns a cell here by design, so this row grows
    /// whenever Switchboard does: the two Gemma routes arrived in one day and pushed
    /// GEMMA-KAGGLE off the edge. Trimming the row once lasts only until the next route, so
    /// the first arrangement that fits wins instead: as many providers as the notch holds,
    /// with as much air between the cells as it can spare, and the quietest providers folded
    /// into one MORE cell. Scrolling is the last resort, for a notch too narrow even for that.
    ///
    /// The gaps close all the way before anything folds. Folding at 10 pt hid a 6.8M
    /// provider inside "3 MORE" alongside two that had done almost nothing, for want of 7 pt.
    private var usageRow: some View {
        let providers = weekProviders
        let fits = (0...providers.count).reversed().flatMap { shown in
            [14, 10, 8, 6].map { (shown: shown, spacing: CGFloat($0)) }
        }
        return ViewThatFits(in: .horizontal) {
            ForEach(fits.indices, id: \.self) { i in
                usageLine(providers, shown: fits[i].shown, spacing: fits[i].spacing)
            }
            row { caption("TOKENS USED"); usageCells(providers, shown: providers.count) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func usageLine(_ providers: [(key: String, value: RouterUsageTotals)],
                           shown: Int, spacing: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            caption("TOKENS USED")
            usageCells(providers, shown: shown)
        }
        .padding(.horizontal, 8)
    }

    /// Upstreams that saw traffic this week, busiest first, so the ones folded away when the
    /// row runs out of room are the ones that did the least.
    private var weekProviders: [(key: String, value: RouterUsageTotals)] {
        usage.byUpstream(for: .week)
            // A provider at zero spends a full cell to say nothing.
            .filter { $0.value.billedTokens > 0 }
            .sorted { $0.value.billedTokens > $1.value.billedTokens }
    }

    // MARK: Cells

    /// - Parameter shown: how many of `providers` get a cell of their own; the rest share one.
    @ViewBuilder
    private func usageCells(_ providers: [(key: String, value: RouterUsageTotals)],
                            shown: Int) -> some View {
        if usage.isAvailable {
            // Billed tokens, not the total. Cache reads outweigh real work by two orders of
            // magnitude on a normal day, so folding them in would read as enormous usage
            // every single day and mean nothing; cache gets its own cell.
            ForEach(Self.distinctWindows(usage), id: \.self) { window in
                tokenGauge(window.label, usage.totals(for: window).billedTokens)
            }
            tokenGauge("CACHED", usage.totals(for: .all).cachedTokens)
            let spend = usage.totals(for: .all).cost
            if spend > 0 {
                let text = String(format: "$%.2f", spend)
                gauge("SPENT", text, widest: text)
            }
            if !providers.isEmpty {
                // A rule rather than a second caption. "ANTHROPIC" next to "ALL TIME" needs
                // separating, but a caption costs its own text width on a row that has none
                // to spare -- and a provider's name already says what it is.
                Divider().frame(height: 10)
                ForEach(providers.prefix(shown), id: \.key) { entry in
                    tokenGauge(entry.key.uppercased(), entry.value.billedTokens)
                }
                if shown < providers.count {
                    let rest = providers.dropFirst(shown)
                    tokenGauge("\(rest.count) MORE", rest.reduce(0) { $0 + $1.value.billedTokens })
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

    /// A token count in a cell that reserves its own figure's width, not the row's widest.
    ///
    /// The digits are monospaced, so a figure only changes width when it gains a digit or a
    /// unit -- a reservation of anything more is dead space. Two shared reservations came
    /// before this and both were wrong. Hard-coding `"999.9M"` reserved a hundred million
    /// tokens' room nine times over, which pushed the merged page past the edge. Sizing to the
    /// largest *value* instead picked `8.4B` beside a MONTH of `114.1M`, so the longest figure
    /// on the row sat in the narrowest slot and drew over the gap into CACHED.
    private func tokenGauge(_ label: String, _ count: Int) -> some View {
        let text = Self.compact(count)
        return gauge(label, text, widest: text)
    }

    /// Every subscription's own meters, on one page. These are quota, not money, which is
    /// why they cannot come from the request log — the proxy sees tokens, not the plan. The
    /// statusline publishes Claude's beside the log from the JSON Claude Code hands it; the
    /// router writes Kimi's to `kimi-limits.json` after each Kimi request, because it holds
    /// that credential and this app holds none.
    ///
    /// Two cells per plan, not four: each reset countdown rides in the cell it qualifies.
    /// Split out, a countdown needed its own label, and "RESETS IN" repeated down the row
    /// was the loudest thing on a page whose actual content is percentages.
    ///
    /// That halving is what makes one page affordable. A page per vendor is the tidier rule
    /// on paper and the worse one in the notch — the strip flips on a timer, so a second
    /// page is not a second place to look, it is a wait. Both plans answer the same
    /// question, and the answer is only useful side by side.
    ///
    /// The long Kimi window is the billing month, and a month reads in days: "30d 4h", not
    /// "720h". Labels carry the plan name because the caption can no longer.
    @ViewBuilder
    private var limitCells: some View {
        if let limits = usage.limits {
            gauge("CLAUDE 5H", "\(Int(limits.fiveHourPercent.rounded()))%", widest: "100%",
                  detail: Self.countdown(to: limits.fiveHourResetsAt), detailWidest: "23h 59m",
                  tint: StatsPalette.severity(limits.fiveHourPercent / 100),
                  alarming: limits.fiveHourPercent >= 90)
            gauge("CLAUDE 7D", "\(Int(limits.sevenDayPercent.rounded()))%", widest: "100%",
                  detail: Self.countdown(to: limits.sevenDayResetsAt), detailWidest: "9d 23h",
                  tint: StatsPalette.severity(limits.sevenDayPercent / 100),
                  alarming: limits.sevenDayPercent >= 90)
        }
        if let kimi = usage.kimiLimits {
            gauge("KIMI 5H", "\(Int(kimi.fiveHourPercent.rounded()))%", widest: "100%",
                  detail: Self.countdown(to: kimi.fiveHourResetsAt), detailWidest: "23h 59m",
                  tint: StatsPalette.severity(kimi.fiveHourPercent / 100),
                  alarming: kimi.fiveHourPercent >= 90)
            gauge("KIMI MONTH", "\(Int(kimi.monthPercent.rounded()))%", widest: "100%",
                  detail: Self.countdown(to: kimi.monthResetsAt), detailWidest: "99d 23h",
                  tint: StatsPalette.severity(kimi.monthPercent / 100),
                  alarming: kimi.monthPercent >= 90)
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
            // One label, and an arrow carries the direction.
            //
            // Two earlier attempts were both wrong in the same way. `POWER IN` / `POWER OUT`
            // renamed the cell depending on whether a cable was plugged in, so "where is
            // POWER IN" reads as a missing feature rather than as a state. Replacing that
            // with a signed figure fixed the label and introduced a minus sign sitting in
            // the row all day, which is just as irritating and less legible at 10pt.
            //
            // An arrow says the same thing without either problem: the cell keeps one name,
            // the direction is visible at a glance, and the number is only ever a number.
            gauge("POWER",
                  String(format: "%@ %.1f W", charging ? "↑" : "↓", abs(stats.batteryWatts)),
                  widest: "↓ 99.9 W",
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
            // Earbuds put both numbers in the one cell rather than earning a second cell
            // that repeats the lower of them: `percent` is by definition `min(L, R)`, so a
            // name cell plus an L and an R would spend three slots saying two things. The
            // tint still tracks the weaker bud -- that is the one that ends the call.
            gauge(device.name.uppercased(),
                  device.reading,
                  widest: device.isSplit ? "L100 R100" : "100%",
                  tint: StatsPalette.severity(1 - Double(device.percent) / 100),
                  trend: device.history,
                  alarming: device.percent <= 10)
            // The case is absent far more often than the buds are -- it reports only while
            // awake and in range -- so it appears and disappears on its own rather than
            // leaving a permanent empty third of the earbud cell.
            if let caseCharge = device.caseCharge {
                gauge("CASE", "\(caseCharge)%",
                      widest: "100%",
                      tint: StatsPalette.severity(1 - Double(caseCharge) / 100),
                      alarming: caseCharge <= 10)
            }
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
            gauge("MEMORY", Units.bytes(stats.memoryUsedBytes),
                  widest: Units.widestBytes,
                  tint: StatsPalette.severity(stats.memoryFraction),
                  trend: stats.memoryHistory,
                  alarming: stats.memoryFraction >= 0.9)
        }
        // Swap before disk: it is the one that moves minute to minute, and the one that
        // explains a machine that feels slow while CPU and memory both look fine.
        if stats.swapTotalBytes > 0 {
            gauge("SWAP", Units.bytes(stats.swapUsedBytes),
                  widest: Units.widestBytes,
                  tint: StatsPalette.severity(stats.swapFraction),
                  trend: stats.swapHistory,
                  alarming: stats.swapFraction >= 0.5)
        }
        if stats.diskTotalBytes > 0 {
            gauge("DISK FREE", Units.bytes(UInt64(max(stats.diskFreeBytes, 0))),
                  widest: Units.widestBytes,
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
        // Signal first: it is the one that explains the others when they are bad.
        if stats.wifiRSSI != 0 {
            // −30 is excellent, −90 is unusable; the ramp is inverted so worse reads hotter.
            let quality = min(max(Double(-stats.wifiRSSI - 30) / 60, 0), 1)
            gauge("SIGNAL", "\(stats.wifiRSSI) dBm",
                  widest: "-99 dBm",
                  tint: StatsPalette.severity(quality),
                  alarming: stats.wifiRSSI <= -75)
        }
        if stats.wifiRate > 0 {
            gauge("LINK", Units.bitRate(megabitsPerSecond: stats.wifiRate),
                  widest: Units.widestBitRate)
        }
        if let ip = stats.localIP {
            gauge("IP", ip, widest: "255.255.255.255")
        }
        // The LAN address above is unchanged by a VPN taking the default route, so it cannot
        // tell you which way traffic is leaving. Tinted when tunnelled, so the answer is a
        // glance rather than a reading.
        if stats.egressLabel != nil {
            let tunnelled = stats.egressLabel != "DIRECT"
            gauge("VIA", stats.egressDisplay,
                  widest: "MyNetwork · NORDVPN",
                  tint: tunnelled ? StatsPalette.good : nil)
        }
        if showNetwork {
            gauge("DOWN", Units.byteRate(stats.networkDownBytesPerSec),
                  widest: Units.widestByteRate,
                  trend: stats.networkDownHistory)
            gauge("UP", Units.byteRate(stats.networkUpBytesPerSec),
                  widest: Units.widestByteRate,
                  trend: stats.networkUpHistory)
        }
    }

    // Sized to sit under the player, not to compete with it. At 12 pt semibold the row
    // read as a second headline; the song title itself is only .headline. A footer should
    // be the quietest thing in the notch while still being legible at a glance.
    private static let valueFont = Font.system(size: 10, weight: .medium, design: .rounded)
        .monospacedDigit()

    /// The subordinate figure in a cell that carries two. Deliberately smaller and dimmer
    /// than `valueFont`: a countdown qualifies the percentage beside it, so drawing the two
    /// at equal weight is what made a two-fact page read as four columns.
    private static let detailFont = Font.system(size: 8.5, weight: .medium, design: .rounded)
        .monospacedDigit()

    /// - Parameter widest: the longest string this cell can ever display. The cell reserves
    ///   that width up front, so a figure going from `9 KB/s` to `912 KB/s` does not shove
    ///   every cell to its right along the row. Monospaced digits alone are not enough —
    ///   they fix the width of a digit, not the number of digits or the length of a unit.
    /// - Parameter detail: a second figure that *qualifies* the first rather than standing
    ///   beside it — a reset countdown against a percentage. It shares the cell so the pair
    ///   reads as one fact, which is the whole reason it exists: given its own cell it needs
    ///   its own label, and a label like "RESETS IN" repeated down the row is louder than
    ///   either number it introduces.
    /// - Parameter detailWidest: `widest`, for the detail. Same reservation, same reason.
    private func gauge(
        _ label: String,
        _ value: String,
        widest: String,
        detail: String? = nil,
        detailWidest: String = "",
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
                            // Swapped, not rolled. The rolling-digit transition was lovely
                            // on a figure that changes now and then, but network speed and
                            // CPU change every second, so the row was mid-animation almost
                            // all the time -- redrawing its digits in software at the full
                            // refresh rate. That was the spike whenever this row showed.
                            .fixedSize()
                    }

                if let detail {
                    Text(detailWidest.isEmpty ? detail : detailWidest)
                        .font(Self.detailFont)
                        .hidden()
                        .overlay(alignment: .leading) {
                            Text(detail)
                                .font(Self.detailFont)
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize()
                        }
                }

                // Rendered as soon as the cell has any trace at all, even before there
                // are two samples to join. Gating on trend.count > 1 meant the plot
                // appeared a second after the notch opened and pushed every figure to its
                // right along the row — the graph loading was itself the jolt.
                if showSparklines, let trend {
                    // A Canvas cannot interpolate between two traces, so animating it
                    // only opened a transaction every second for nothing.
                    Sparkline(values: trend, color: accent)
                }
            }
        }
        .fixedSize()
    }

    // MARK: Formatting

    private static func compact(_ count: Int) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.1fB", Double(count) / 1_000_000_000)
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
}

// MARK: - Home-only attachment

extension View {
    /// The strip belongs to home, not to every tab.
    ///
    /// `safeAreaInset` with `spacing: 0` reserves exactly `statsStripHeight`. A plain `VStack`
    /// sibling would also add the stack's default spacing, so the row would eat more than the
    /// notch grew by and squeeze the player again.
    ///
    /// Keeping it a modifier rather than inline in `ContentView` means the fork's diff against
    /// upstream there stays a single word on one branch.
    func notchStatsStrip(gestureProgress: CGFloat, isOpen: Bool) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if Defaults[.showStatsStrip] {
                NotchStatsStrip()
                    .allowsHitTesting(isOpen)
                    .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
    }
}
