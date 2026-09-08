//
//  Sparkline.swift
//  boringNotch
//
//  The small trace that sits beside a figure.
//

import SwiftUI

/// A filled trace, shaped the way the system's own small graphs are — a soft gradient area
/// under a thin line, rather than the bare polyline a dashboard library would draw.
///
/// Values are already normalised to 0...1 by whoever produced them, so this never has to know
/// the units it is drawing.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var size: CGSize = .init(width: 22, height: 9)

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }

            let step = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let clamped = min(max(values[index], 0), 1)
                // A little headroom so a trace pinned at 100% still reads as a line rather
                // than merging with the top edge.
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
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
