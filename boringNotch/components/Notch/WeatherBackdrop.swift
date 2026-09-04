//
//  WeatherBackdrop.swift
//  boringNotch
//
//  The sky behind the notch's content.
//

import Defaults
import SwiftUI

/// A live sky drawn behind everything in the open notch, then buried under frosted glass.
///
/// The frosting is the whole reason this can exist at all. The album art already owns the
/// backdrop — `lightingEffect` blurs the artwork behind itself as a colour glow and
/// `playerColorTinting` pushes its average colour into the artist line and the scrubber —
/// so a sky competing at full strength would fight the record sleeve for the same pixels,
/// and the sleeve wins on relevance every time. Behind glass it stops competing: what comes
/// through is ambient light and motion, not imagery, and the album art still reads first.
///
/// Everything is drawn in a single `Canvas` pass at 30 fps. The notch has form here — a
/// leaked 3-second timer once ran it to 31.7% CPU, and the audio visualiser costs about 20%
/// while the notch is open — so this deliberately does not spawn a view per particle or
/// animate at 60. It renders only while the notch is open, because the view only exists
/// then.
struct WeatherBackdrop: View {
    let condition: SkyCondition
    let isDay: Bool
    /// 0...1. Scales every element's opacity together, so "less distracting" is one knob.
    let intensity: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                draw(in: &context, size: size, time: time)
            }
            .drawingGroup()
        }
        .background(sky)
        // The glass. Content sits above this, so the sky reads as light rather than as a
        // picture, and text keeps its contrast.
        .overlay(.ultraThinMaterial.opacity(0.82))
        .overlay(Color.black.opacity(0.42))
        .allowsHitTesting(false)
    }

    // MARK: - Sky

    private var sky: some View {
        LinearGradient(colors: skyColors, startPoint: .top, endPoint: .bottom)
    }

    private var skyColors: [Color] {
        guard isDay else {
            // Night is nearly black on purpose — the notch is a black shape and should
            // still read as one.
            switch condition {
            case .storm: return [Color(red: 0.05, green: 0.05, blue: 0.10), .black]
            case .fog: return [Color(red: 0.09, green: 0.09, blue: 0.11), .black]
            default: return [Color(red: 0.03, green: 0.05, blue: 0.14), .black]
            }
        }
        switch condition {
        case .clear: return [Color(red: 0.16, green: 0.36, blue: 0.62), Color(red: 0.03, green: 0.08, blue: 0.18)]
        case .cloudy: return [Color(red: 0.22, green: 0.25, blue: 0.30), Color(red: 0.05, green: 0.06, blue: 0.09)]
        case .fog: return [Color(red: 0.26, green: 0.27, blue: 0.29), Color(red: 0.08, green: 0.08, blue: 0.09)]
        case .rain: return [Color(red: 0.16, green: 0.20, blue: 0.27), Color(red: 0.03, green: 0.05, blue: 0.08)]
        case .snow: return [Color(red: 0.28, green: 0.31, blue: 0.36), Color(red: 0.07, green: 0.08, blue: 0.11)]
        case .storm: return [Color(red: 0.10, green: 0.11, blue: 0.16), .black]
        }
    }

    // MARK: - Scene

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        if isDay {
            if condition == .clear || condition == .cloudy { drawSun(&context, size, time) }
        } else {
            drawStars(&context, size, time)
            drawShootingStar(&context, size, time)
        }

        switch condition {
        case .rain, .storm: drawPrecipitation(&context, size, time, isSnow: false)
        case .snow: drawPrecipitation(&context, size, time, isSnow: true)
        case .cloudy, .fog: drawClouds(&context, size, time)
        case .clear: break
        }
    }

    /// A soft bloom rather than a disc. Bright enough to notice at a glance, nowhere near
    /// bright enough to look at — the whole point is that it sits under the music.
    private func drawSun(_ context: inout GraphicsContext, _ size: CGSize, _ time: Double) {
        let centre = CGPoint(x: size.width * 0.78, y: size.height * 0.30)
        // A slow breath, a few percent either way. Anything more reads as a flicker.
        let pulse = 1 + 0.05 * sin(time * 0.6)
        let radius = size.height * 0.85 * pulse

        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 1.0, green: 0.92, blue: 0.70).opacity(0.55 * intensity),
                    Color(red: 1.0, green: 0.80, blue: 0.45).opacity(0.16 * intensity),
                    .clear,
                ]),
                center: centre, startRadius: 0, endRadius: radius))
    }

    private func drawStars(_ context: inout GraphicsContext, _ size: CGSize, _ time: Double) {
        // Deterministic from the index, so the field is stable frame to frame without
        // storing any state.
        for index in 0..<46 {
            let seed = Double(index)
            let x = fract(sin(seed * 12.9898) * 43758.5453) * size.width
            let y = fract(sin(seed * 78.233) * 24634.6345) * size.height * 0.8
            let phase = fract(sin(seed * 39.425) * 11223.334) * 6.283
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(time * 1.4 + phase))
            let radius = 0.5 + fract(sin(seed * 4.771) * 3251.11) * 0.9

            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(0.9 * twinkle * intensity)))
        }
    }

    /// One streak every ~7 seconds, crossing in under a second. Rare enough to be a small
    /// event rather than wallpaper.
    private func drawShootingStar(_ context: inout GraphicsContext, _ size: CGSize, _ time: Double) {
        let period = 7.0
        let cycle = time.truncatingRemainder(dividingBy: period)
        let travel = 0.9
        guard cycle < travel else { return }

        let progress = cycle / travel
        let index = floor(time / period)
        let startX = fract(sin(index * 91.17) * 8123.7) * size.width * 0.6
        let startY = fract(sin(index * 17.31) * 5417.3) * size.height * 0.4

        let dx = size.width * 0.34, dy = size.height * 0.42
        let head = CGPoint(x: startX + dx * progress, y: startY + dy * progress)
        let tail = CGPoint(x: head.x - dx * 0.22, y: head.y - dy * 0.22)

        // Fades in and out across its flight so it never pops.
        let fade = sin(progress * .pi)

        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [.clear, .white.opacity(0.85 * fade * intensity)]),
                startPoint: tail, endPoint: head),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    private func drawPrecipitation(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double, isSnow: Bool
    ) {
        let count = isSnow ? 34 : 52
        let speed = isSnow ? 0.10 : 0.75

        for index in 0..<count {
            let seed = Double(index)
            let column = fract(sin(seed * 12.9898) * 43758.5453)
            let offset = fract(sin(seed * 78.233) * 24634.6345)
            let drift = isSnow ? sin(time * 0.7 + seed) * size.width * 0.02 : 0
            let y = fract(offset + time * speed) * size.height
            let x = column * size.width + drift

            if isSnow {
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: 2.1, height: 2.1)),
                    with: .color(.white.opacity(0.55 * intensity)))
            } else {
                var streak = Path()
                streak.move(to: CGPoint(x: x, y: y))
                streak.addLine(to: CGPoint(x: x - 1.5, y: y + 9))
                context.stroke(
                    streak,
                    with: .color(Color(red: 0.72, green: 0.82, blue: 0.95).opacity(0.42 * intensity)),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
    }

    private func drawClouds(_ context: inout GraphicsContext, _ size: CGSize, _ time: Double) {
        for index in 0..<4 {
            let seed = Double(index)
            let speed = 0.006 + fract(sin(seed * 21.7) * 3312.9) * 0.008
            let x = fract(fract(sin(seed * 12.9) * 4471.3) + time * speed) * (size.width + 260) - 130
            let y = size.height * (0.16 + fract(sin(seed * 55.1) * 1129.7) * 0.5)
            let width = size.height * (1.3 + fract(sin(seed * 8.3) * 771.1) * 1.1)

            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: width, height: width * 0.42)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.16 * intensity), .clear]),
                    center: CGPoint(x: x + width / 2, y: y + width * 0.21),
                    startRadius: 0, endRadius: width * 0.5))
        }
    }

    /// Fractional part — the cheap deterministic hash these scenes are built on.
    private func fract(_ value: Double) -> Double { value - floor(value) }
}
