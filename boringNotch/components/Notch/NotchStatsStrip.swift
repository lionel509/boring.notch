//
//  NotchStatsStrip.swift
//  boringNotch
//
//  The bottom row of the expanded notch: API usage, then system load.
//

import Defaults
import SwiftUI

/// One row pinned under the notch's content: what the APIs have cost today on the left,
/// what the machine is doing on the right.
///
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
            // inside MusicPlayerView. At 3 pt the row read as very slightly left of
            // everything above it.
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

    // MARK: - Chips

    @ViewBuilder
    private var usageChips: some View {
        if usage.isAvailable {
            let totals = usage.combined
            // Billed tokens lead, not the total. Cache reads outweigh real work by two
            // orders of magnitude on a normal day — 87.7M against 779k — so folding them
            // into one figure would read as enormous usage every single day and mean
            // nothing. They get their own chip instead, where the ratio is the point.
            chip("bolt.horizontal.fill", Self.tokens(totals.billedTokens))
            if totals.cachedTokens > 0 {
                chip("archivebox.fill", Self.tokens(totals.cachedTokens))
            }
            if totals.cost > 0 {
                chip("dollarsign.circle.fill", String(format: "%.2f", totals.cost))
            }
            chip("arrow.triangle.2.circlepath", "\(totals.requests)")
        } else if usage.needsAuthorization {
            // The sandbox, not a missing file. Settings has the button that fixes it.
            chip("lock.fill", "grant log access")
        } else {
            chip("bolt.horizontal", "no router log")
        }
    }

    @ViewBuilder
    private var systemChips: some View {
        chip("cpu.fill", "\(Int((stats.cpuUsage * 100).rounded()))%")
        chip("memorychip.fill", Self.gigabytes(stats.memoryUsedBytes))
        chip("arrow.down", Self.rate(stats.networkDownBytesPerSec))
        chip("arrow.up", Self.rate(stats.networkUpBytesPerSec))
    }

    private func chip(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(value)
                // Monospaced digits are not cosmetic here: without them every chip
                // changes width each second and the whole row twitches.
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    // MARK: - Formatting

    private static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(count) / 1_000)
        default: return "\(count)"
        }
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1fG", Double(bytes) / 1_073_741_824)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1_048_576...: return String(format: "%.1fM", bytesPerSecond / 1_048_576)
        case 1_024...: return String(format: "%.0fK", bytesPerSecond / 1_024)
        default: return "0"
        }
    }
}
