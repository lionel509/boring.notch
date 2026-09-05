//
//  WeatherBackdrop.swift
//  boringNotch
//
//  The sky behind the notch's content.
//

import AppKit
import Defaults
import SwiftUI

/// Real behind-window blur — the desktop showing through, not a simulation of it.
/// The notch window is already `isOpaque = false` with a clear background, so this
/// samples whatever is actually behind it: wallpaper, or the window under it.
private struct DesktopBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

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
    /// Show the real desktop through frosted glass rather than a painted sky.
    let useDesktopBlur: Bool
    /// 0 at sunrise, 1 at sunset. Drives where the sun sits and how warm it is.
    let sunProgress: Double
    /// 0 and 1 new, 0.25 first quarter, 0.5 full. Drives the terminator.
    let moonPhase: Double
    /// 0 at moonrise, 1 at moonset; nil while the moon is below the horizon.
    let moonProgress: Double?

    /// How often the scene redraws.
    ///
    /// The first version ran everything at a flat 30 fps, which is a full-notch canvas
    /// repaint 30 times a second to animate a sun that breathes once every ten — and it
    /// showed up as the calendar's date wheel feeling sticky while scrolling. Only the
    /// conditions with fast-moving particles actually need 30.
    private var frameInterval: Double {
        if !isDay { return 1.0 / 20.0 }          // twinkle and the occasional streak
        switch condition {
        case .rain, .storm, .snow: return 1.0 / 30.0   // falling, genuinely needs frames
        case .cloudy: return 1.0 / 12.0                // drifting
        case .fog, .clear: return 4.0                  // nothing moves but the sun, and it
                                                       // crosses the sky over hours
        }
    }

    var body: some View {
        ZStack {
            if useDesktopBlur {
                // The wallpaper itself, blurred, with the sky laid over it as a tint. Real
                // glass beats a painted imitation, and it means the notch picks up whatever
                // is behind it rather than inventing a backdrop.
                DesktopBlur()
                // A wash, not a coat. At 55% the sky stacked on top of the album art's own
                // lighting effect — which already tints the whole notch from the artwork —
                // and two tinting systems fighting over the same pixels came out muddy
                // brown rather than like glass. The blur is the effect; the weather only
                // colours it.
                sky.opacity(0.18)
            } else {
                sky
            }

            TimelineView(.animation(minimumInterval: frameInterval, paused: false)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }

            // Enough scrim to keep white text readable over a bright wallpaper, and no more.
            // An early pass stacked 82% material on a 42% black scrim, which on a sunny
            // afternoon made the notch indistinguishable from plain black — frosting is
            // meant to soften the backdrop, not delete it.
            Color.black.opacity(useDesktopBlur ? 0.22 : 0.18)
        }
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
        case .clear:
            // Blend the daytime blue toward dusk as the sun nears the horizon.
            let dusk = 1 - sin(min(max(sunProgress, 0), 1) * .pi)
            return [
                Color(red: 0.24 + 0.42 * dusk, green: 0.52 - 0.16 * dusk, blue: 0.86 - 0.50 * dusk),
                Color(red: 0.06 + 0.16 * dusk, green: 0.16 - 0.04 * dusk, blue: 0.38 - 0.14 * dusk),
            ]
        case .cloudy: return [Color(red: 0.36, green: 0.42, blue: 0.51), Color(red: 0.10, green: 0.12, blue: 0.17)]
        case .fog: return [Color(red: 0.44, green: 0.46, blue: 0.49), Color(red: 0.13, green: 0.14, blue: 0.16)]
        case .rain: return [Color(red: 0.26, green: 0.34, blue: 0.46), Color(red: 0.06, green: 0.09, blue: 0.15)]
        case .snow: return [Color(red: 0.44, green: 0.49, blue: 0.57), Color(red: 0.12, green: 0.14, blue: 0.19)]
        case .storm: return [Color(red: 0.17, green: 0.19, blue: 0.27), Color(red: 0.03, green: 0.03, blue: 0.06)]
        }
    }

    // MARK: - Scene

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        if isDay {
            if condition == .clear || condition == .cloudy { drawSun(&context, size, time) }
        } else {
            drawStars(&context, size, time)
            if condition == .clear || condition == .cloudy { drawMoon(&context, size) }
            drawShootingStar(&context, size, time)
        }

        switch condition {
        case .rain, .storm: drawPrecipitation(&context, size, time, isSnow: false)
        case .snow: drawPrecipitation(&context, size, time, isSnow: true)
        case .cloudy, .fog: drawClouds(&context, size, time)
        case .clear: break
        }
    }

    /// A soft bloom rather than a disc, tracking the real sun across the sky rather than
    /// parking in one corner. Bright enough to notice at a glance, nowhere near bright
    /// enough to look at — the point is that it sits under the music.
    private func drawSun(_ context: inout GraphicsContext, _ size: CGSize, _ time: Double) {
        // Left to right across the day, and an arc that is high at noon and on the horizon
        // at either end.
        let arc = sin(min(max(sunProgress, 0), 1) * .pi)
        let centre = CGPoint(
            x: size.width * (0.12 + 0.76 * sunProgress),
            y: size.height * (1.02 - 0.86 * arc))
        let radius = size.height * (0.75 + 0.45 * arc)

        // Low sun goes warm. Golden hour is most of why anyone looks at a sunset.
        let warmth = 1 - arc
        let core = Color(
            red: 1.0,
            green: 0.95 - 0.22 * warmth,
            blue: 0.78 - 0.52 * warmth)
        let halo = Color(
            red: 1.0,
            green: 0.82 - 0.28 * warmth,
            blue: 0.48 - 0.36 * warmth)

        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    core.opacity(0.85 * intensity),
                    halo.opacity(0.30 * intensity),
                    .clear,
                ]),
                center: centre, startRadius: 0, endRadius: radius))
    }

    /// The moon, at tonight's real phase and in roughly the right part of the sky.
    ///
    /// Unlike the sun this is a disc rather than a bloom, because the shape is the whole
    /// point — a gibbous moon that renders as a soft circle is just a dim sun. The lit
    /// region is the limb on one side closed by the terminator on the other, where the
    /// terminator is an ellipse whose width is cos(2*pi*phase): +1 at new (the two curves
    /// coincide and nothing is drawn, which is correct), 0 at the quarters (a straight
    /// edge, half lit), -1 at full (a complete circle). Waning phases mirror, so the lit
    /// side swaps over as it should.
    private func drawMoon(_ context: inout GraphicsContext, _ size: CGSize) {
        guard let progress = moonProgress else { return }

        let arc = sin(min(max(progress, 0), 1) * .pi)
        let centre = CGPoint(
            x: size.width * (0.14 + 0.72 * progress),
            y: size.height * (0.92 - 0.72 * arc))
        let radius = size.height * 0.11

        // Fades out at the horizon rather than clipping off the bottom edge.
        let visibility = min(arc * 2.4, 1)
        // A sliver carries far less light than a full moon, and drawing them equally bright
        // is the tell that a moon is decorative rather than observed.
        let lit = (1 - cos(2 * .pi * moonPhase)) / 2
        guard lit > 0.02, visibility > 0.01 else { return }

        let glow = radius * 3.2
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - glow, y: centre.y - glow, width: glow * 2, height: glow * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.85, green: 0.88, blue: 1.0)
                        .opacity(0.22 * lit * visibility * intensity),
                    .clear,
                ]),
                center: centre, startRadius: 0, endRadius: glow))

        let terminatorWidth = cos(2 * .pi * moonPhase)
        let mirror: Double = moonPhase > 0.5 ? -1 : 1
        let steps = 28

        var disc = Path()
        // The lit limb: the half of the circle facing the sun.
        for step in 0...steps {
            let angle = -Double.pi / 2 + Double.pi * Double(step) / Double(steps)
            let point = CGPoint(
                x: centre.x + mirror * radius * cos(angle),
                y: centre.y + radius * sin(angle))
            if step == 0 { disc.move(to: point) } else { disc.addLine(to: point) }
        }
        // The terminator, back the other way.
        for step in 0...steps {
            let angle = Double.pi / 2 - Double.pi * Double(step) / Double(steps)
            disc.addLine(to: CGPoint(
                x: centre.x + mirror * radius * terminatorWidth * cos(angle),
                y: centre.y + radius * sin(angle)))
        }
        disc.closeSubpath()

        context.fill(
            disc,
            with: .color(Color(red: 0.96, green: 0.96, blue: 0.92)
                .opacity(0.82 * visibility * intensity)))
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
