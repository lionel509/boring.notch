//
//  StatCell.swift
//  boringNotch
//
//  The one way a figure is drawn anywhere in the notch.
//

import Defaults
import SwiftUI

/// A quiet uppercase label over a figure, with an optional trace beside it.
///
/// The hierarchy is the point: a row where the label and the value carry identical weight
/// reads as chrome, and the number is the thing being read. Every readout in every tab goes
/// through this type, so thirteen sub-pages built separately still read as one app.
struct StatCell: View {
    let label: String
    let value: String
    /// The longest string this cell can ever display. The cell reserves that width up front,
    /// so a figure going from `9 KB/s` to `912 KB/s` does not shove every cell to its right
    /// along the row. Monospaced digits alone are not enough — they fix the width of a digit,
    /// not the number of digits or the length of a unit.
    let widest: String
    var tint: Color?
    var trend: [Double]?
    var alarming: Bool = false

    @Default(.statsStripSparklines) private var showSparklines
    @Default(.statsStripColor) private var useColor

    /// Sized to sit under the player, not to compete with it. At 12 pt semibold the row read
    /// as a second headline; the song title itself is only `.headline`.
    static let valueFont = Font.system(size: 10, weight: .medium, design: .rounded)
        .monospacedDigit()

    static let labelFont = Font.system(size: 6.5, weight: .semibold)

    var body: some View {
        let accent = useColor ? (tint ?? .effectiveAccent) : .secondary

        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(Self.labelFont)
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

                // Rendered as soon as the cell has any trace at all, even before there are two
                // samples to join. Gating on `count > 1` meant the plot appeared a second after
                // the notch opened and pushed every figure to its right along the row — the
                // graph loading was itself the jolt.
                if showSparklines, let trend {
                    Sparkline(values: trend, color: accent)
                        .animation(.smooth(duration: 0.35), value: trend)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
