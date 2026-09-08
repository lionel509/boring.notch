//
//  PanelChrome.swift
//  boringNotch
//
//  The shared vocabulary every panel is assembled from.
//

import SwiftUI

/// 578 x 150 is a *wide* box, so a panel is columns of facts, not a list.
/// Rule of thumb: 3-4 columns of up to 4 rows. Anything wanting more is the wrong shape for
/// a notch and should be split into two panels.
struct PanelColumn<Content: View>: View {
    let title: String
    var width: CGFloat = 150
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 7, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
            content
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Label left, value right. The value is monospaced-digit so a changing number never reflows
/// the row, which is the same discipline `StatCell` applies to the strip.
struct PanelRow: View {
    let label: String
    let value: String
    var tint: Color?
    var status: PanelStatus?

    var body: some View {
        HStack(spacing: 6) {
            if let status { StatusDot(status: status) }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(tint ?? .white.opacity(0.92))
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.35), value: value)
                .lineLimit(1)
        }
        .frame(height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

enum PanelStatus {
    case up, warn, down, unknown

    var color: Color {
        switch self {
        case .up: StatsPalette.good
        case .warn: StatsPalette.serious
        case .down: StatsPalette.critical
        case .unknown: .white.opacity(0.25)
        }
    }

    /// Colour is never the only channel — a dot also differs in fill so it survives both
    /// colour blindness and a greyscale screenshot.
    var filled: Bool { self != .unknown }
}

struct StatusDot: View {
    let status: PanelStatus

    var body: some View {
        Circle()
            .strokeBorder(status.color, lineWidth: status.filled ? 0 : 1)
            .background(Circle().fill(status.filled ? status.color : .clear))
            .frame(width: 5, height: 5)
            .accessibilityHidden(true)
    }
}

/// A horizontal proportion. Used for plan limits and disk, where a percentage reads better as
/// a length than as a number.
struct MeterBar: View {
    let fraction: Double
    var tint: Color?
    var width: CGFloat = 60

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(.white.opacity(0.12))
            .frame(width: width, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint ?? StatsPalette.severity(clamped))
                    .frame(width: max(2, width * clamped), height: 3)
                    .animation(.smooth(duration: 0.35), value: clamped)
            }
            .accessibilityHidden(true)
    }
}

/// Every panel needs all three of these. A blank box reads as broken, and a spinner for a
/// 21 ms query is worse than showing the last value you had.
struct PanelState: View {
    enum Kind { case empty, probing, failed }

    let kind: Kind
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .empty:
                Image(systemName: "minus")
            case .probing:
                Image(systemName: "circle.dotted")
                    .symbolEffect(.pulse, options: .repeating)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
            }
            Text(message)
                .font(.system(size: 10))
        }
        .font(.system(size: 9))
        .foregroundStyle(kind == .failed ? StatsPalette.serious : .white.opacity(0.4))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The height a panel actually has to work with, measured by the host rather than guessed at
/// by each panel.
private struct NotchPanelHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 150
}

extension EnvironmentValues {
    var notchPanelHeight: CGFloat {
        get { self[NotchPanelHeightKey.self] }
        set { self[NotchPanelHeightKey.self] = newValue }
    }
}

/// A long line at row height, scrolling if it does not fit. Belongs in `Kit/PanelChrome.swift`
/// beside `PanelRow` — it lives here only because that file was being edited elsewhere when
/// this was written. The Downloads panel uses it for torrent names.
///
/// A log line at row height, scrolling if it does not fit. `MarqueeText` measures itself and
/// reports a height of zero until it has, so the frame is pinned here — otherwise the first
/// frame of every refresh collapses the row and the column jumps.
struct PanelMarqueeLine: View {
    let text: String
    let width: CGFloat
    var tint: Color?

    var body: some View {
        MarqueeText(
            .constant(text),
            font: .system(size: 10),
            nsFont: .caption1,
            textColor: tint ?? .white.opacity(0.82),
            minDuration: 2.5,
            frameWidth: width)
        .frame(width: width, height: 13)
    }
}
