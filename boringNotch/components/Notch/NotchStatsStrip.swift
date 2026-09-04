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
        .frame(width: 28, height: 14)
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

    @Default(.statsStripShowUsage) private var showUsage
    @Default(.statsStripShowSystem) private var showSystem
    @Default(.statsStripShowCPU) private var showCPU
    @Default(.statsStripShowMemory) private var showMemory
    @Default(.statsStripShowNetwork) private var showNetwork
    @Default(.statsStripSparklines) private var showSparklines
    @Default(.statsStripColor) private var useColor

    /// The notch springs open in ~0.42 s. Rendering the row at full strength from the first
    /// frame makes it read as pasted on. It settles in just behind the expansion instead.
    @State private var settled = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                if showUsage { usageCells }
                if showSystem { systemCells }
            }
            // 5 pt to sit flush under the album art, which carries .padding(.all, 5)
            // inside MusicPlayerView.
            .padding(.horizontal, 5)
        }
        .scrollIndicators(.hidden)
        .frame(height: statsStripHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fade the ends so a scrolled row reads as continuing rather than as clipped.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.03),
                    .init(color: .black, location: 0.97),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .opacity(settled ? 1 : 0)
        .offset(y: settled ? 0 : 7)
        .onAppear {
            stats.start()
            usage.refresh()
            withAnimation(.smooth(duration: 0.3).delay(0.14)) { settled = true }
        }
        .onDisappear {
            settled = false
            // Sampling exists only while this row does. A closed notch costs nothing.
            stats.stop()
        }
    }

    // MARK: Cells

    @ViewBuilder
    private var usageCells: some View {
        if usage.isAvailable {
            let totals = usage.combined
            // Billed tokens lead, not the total. Cache reads outweigh real work by two
            // orders of magnitude on a normal day — 87.7M against 779k — so folding them
            // into one figure would read as enormous usage every single day and mean
            // nothing. Cached gets its own cell, where the ratio is the point.
            gauge("TOKENS", Self.compact(totals.billedTokens))
            if totals.cachedTokens > 0 {
                gauge("CACHED", Self.compact(totals.cachedTokens))
            }
            if totals.cost > 0 {
                gauge("COST", String(format: "$%.2f", totals.cost))
            }
            gauge("REQUESTS", "\(totals.requests)")
        } else if usage.needsAuthorization {
            // The sandbox, not a missing file. Settings has the button that fixes it.
            gauge("API USAGE", "Grant access", tint: StatsPalette.serious)
        } else {
            gauge("API USAGE", "No log")
        }
    }

    @ViewBuilder
    private var systemCells: some View {
        if showCPU {
            gauge("CPU", "\(Int((stats.cpuUsage * 100).rounded()))%",
                  tint: StatsPalette.severity(stats.cpuUsage),
                  trend: stats.cpuHistory,
                  alarming: stats.cpuUsage >= 0.9)
        }
        if showMemory {
            gauge("MEMORY", Self.gigabytes(stats.memoryUsedBytes),
                  tint: StatsPalette.severity(stats.memoryFraction),
                  trend: stats.memoryHistory,
                  alarming: stats.memoryFraction >= 0.9)
        }
        if showNetwork {
            gauge("DOWN", Self.rate(stats.networkDownBytesPerSec), trend: stats.networkHistory)
            gauge("UP", Self.rate(stats.networkUpBytesPerSec))
        }
    }

    private func gauge(
        _ label: String,
        _ value: String,
        tint: Color? = nil,
        trend: [Double]? = nil,
        alarming: Bool = false
    ) -> some View {
        let accent = useColor ? (tint ?? .effectiveAccent) : .secondary

        return VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)

            HStack(spacing: 5) {
                Text(value)
                    // Monospaced digits are not cosmetic: without them the figure changes
                    // width every second and the whole row twitches. numericText rolls the
                    // digits over rather than swapping them.
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(useColor && alarming ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.35), value: value)

                if showSparklines, let trend, trend.count > 1 {
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
