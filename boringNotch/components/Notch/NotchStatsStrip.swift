//
//  NotchStatsStrip.swift
//  boringNotch
//
//  The bottom row of the expanded notch: API usage, then system load.
//

import Defaults
import SwiftUI

// MARK: - Palette

/// Severity steps for the load readouts, and the single hue the network trace uses.
///
/// These are a *status* ramp — an ordered good → warning → serious → critical scale — not
/// series identities, so only one of them is ever on a given metric at a time. Colour is
/// never the only channel: every chip carries an SF Symbol and the number itself, which is
/// what makes an ordered ramp legible when two adjacent steps sit close in hue.
///
/// Verified against this surface rather than assumed: all five clear 3:1 on black, and the
/// worst simultaneously-visible pair separates by ΔE 11.3 under deuteranopia. The one
/// remaining tight pair is warning ↔ serious (ΔE 13.6), which are consecutive steps of the
/// same ordered scale and never appear on the same chip.
private enum StatsPalette {
    static let good = Color(red: 0.047, green: 0.639, blue: 0.047)      // #0ca30c
    static let warning = Color(red: 0.980, green: 0.698, blue: 0.098)   // #fab219
    static let serious = Color(red: 0.925, green: 0.514, blue: 0.353)   // #ec835a
    static let critical = Color(red: 0.816, green: 0.231, blue: 0.231)  // #d03b3b
    static let network = Color(red: 0.224, green: 0.529, blue: 0.898)   // #3987e5

    /// Same 50 / 75 / 90 thresholds the Claude Code statusline uses, so a meter means the
    /// same thing in both places.
    static func severity(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.50: good
        case ..<0.75: warning
        case ..<0.90: serious
        default: critical
        }
    }
}

// MARK: - Sparkline

/// A 12-point trace, sized for a status row rather than a chart.
///
/// The line sits at reduced opacity and the newest sample is a full-strength dot, so the
/// eye lands on *now* and the trail is context. Stroke is 1.2 pt rather than the usual 2:
/// at 10 pt tall a 2 pt line is a fifth of the plot height and reads as a bar.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }

            let step = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let clamped = min(max(values[index], 0), 1)
                return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - clamped))
            }

            var path = Path()
            path.move(to: point(0))
            for index in 1..<values.count { path.addLine(to: point(index)) }

            context.stroke(
                path,
                with: .color(color.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

            let last = point(values.count - 1)
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - 1.4, y: last.y - 1.4, width: 2.8, height: 2.8)),
                with: .color(color))
        }
        .frame(width: 22, height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Strip

/// One `statsStripHeight` row, attached as a bottom safe-area inset so it reserves exactly
/// that much and no more. The notch grows by the same amount when the strip is enabled —
/// see `openNotchSize`, which records why fitting it inside the existing 190 pt did not
/// work. Both groups share a single horizontal scroll axis, so overflow scrolls sideways
/// rather than wrapping, and the notch's height never depends on how many chips there are.
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

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if showUsage {
                    usageChips
                }
                if showUsage && showSystem {
                    Divider().frame(height: 10)
                }
                if showSystem {
                    systemChips
                }
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
        .onAppear {
            stats.start()
            usage.refresh()
        }
        .onDisappear {
            // Sampling exists only while this row does. A closed notch costs nothing.
            stats.stop()
        }
    }

    // MARK: Chips

    @ViewBuilder
    private var usageChips: some View {
        if usage.isAvailable {
            let totals = usage.combined
            // Billed tokens lead, not the total. Cache reads outweigh real work by two
            // orders of magnitude on a normal day — 87.7M against 779k — so folding them
            // into one figure would read as enormous usage every single day and mean
            // nothing. They get their own chip instead, where the ratio is the point.
            chip("bolt.horizontal.fill", Self.tokens(totals.billedTokens), tint: StatsPalette.network)
            if totals.cachedTokens > 0 {
                chip("archivebox.fill", Self.tokens(totals.cachedTokens))
            }
            if totals.cost > 0 {
                chip("dollarsign.circle.fill", String(format: "%.2f", totals.cost),
                     tint: StatsPalette.warning)
            }
            chip("arrow.triangle.2.circlepath", "\(totals.requests)")
        } else if usage.needsAuthorization {
            // The sandbox, not a missing file. Settings has the button that fixes it.
            chip("lock.fill", "grant log access", tint: StatsPalette.warning)
        } else {
            chip("bolt.horizontal", "no router log")
        }
    }

    @ViewBuilder
    private var systemChips: some View {
        if showCPU {
            chip("cpu.fill", "\(Int((stats.cpuUsage * 100).rounded()))%",
                 tint: StatsPalette.severity(stats.cpuUsage),
                 trend: stats.cpuHistory)
        }
        if showMemory {
            chip("memorychip.fill", Self.gigabytes(stats.memoryUsedBytes),
                 tint: StatsPalette.severity(stats.memoryFraction),
                 trend: stats.memoryHistory)
        }
        if showNetwork {
            chip("arrow.down", Self.rate(stats.networkDownBytesPerSec),
                 tint: StatsPalette.network,
                 trend: stats.networkHistory)
            // The arrows carry up-vs-down, so both traces share one hue. Two hues here
            // would be decoration, and the pair that reads best against black — blue and
            // violet — separates by only ΔE 1.9 under protanopia anyway.
            chip("arrow.up", Self.rate(stats.networkUpBytesPerSec), tint: StatsPalette.network)
        }
    }

    private func chip(
        _ symbol: String,
        _ value: String,
        tint: Color? = nil,
        trend: [Double]? = nil
    ) -> some View {
        let accent = (useColor ? tint : nil) ?? .secondary

        return HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
            Text(value)
                // Monospaced digits are not cosmetic here: without them every chip
                // changes width each second and the whole row twitches. The value stays
                // in secondary ink — the coloured icon and trace carry the state, which
                // keeps ten-point text legible on black.
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            if showSparklines, let trend, trend.count > 1 {
                Sparkline(values: trend, color: accent)
            }
        }
        .fixedSize()
    }

    // MARK: Formatting

    private static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(count) / 1_000)
        default: "\(count)"
        }
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1fG", Double(bytes) / 1_073_741_824)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1_048_576...: String(format: "%.1fM", bytesPerSecond / 1_048_576)
        case 1_024...: String(format: "%.0fK", bytesPerSecond / 1_024)
        default: "0"
        }
    }
}
