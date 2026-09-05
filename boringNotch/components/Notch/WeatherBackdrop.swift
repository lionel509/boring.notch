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
    /// Draw the city along the bottom, with its lit windows and passing aircraft.
    let showCity: Bool

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
        case .fog, .clear:
            // Four seconds was right when nothing moved but the sun. With aircraft
            // crossing, four seconds is a plane teleporting a sixth of the way across the
            // sky per frame, so a clear day now redraws at 10 fps — still the cheapest
            // case, and the scene it redraws is roughly half the draw calls it used to be
            // now the stars and the city batch into a handful of fills.
            return showCity ? 1.0 / 10.0 : 4.0
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
            //
            // Weighted toward the bottom, because that is where both the bright half of
            // the scene and the quiet half of the text ended up. The city glow, the neon
            // and the water all sit in the lower third, and so do the scrubber's
            // timestamps and the stats row — which are grey on purpose and stopped being
            // legible the moment a lit skyline appeared behind them. A flat scrim heavy
            // enough to fix that would have taken the sky out with it.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(useDesktopBlur ? 0.20 : 0.16), location: 0),
                    .init(color: .black.opacity(useDesktopBlur ? 0.24 : 0.20), location: 0.45),
                    .init(color: .black.opacity(useDesktopBlur ? 0.46 : 0.42), location: 0.78),
                    .init(color: .black.opacity(useDesktopBlur ? 0.54 : 0.50), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Sky

    /// Black at the top, sky in the middle, water at the bottom.
    ///
    /// The top band is not a stylistic choice: the physical notch is a hole in the
    /// display with no pixels in it, and the panel is wider than the hole. Any colour up
    /// there draws a lit band around a black cutout and the illusion that the notch grew
    /// is over. Starting at black and only reaching sky colour below the cutout's depth
    /// keeps the seam invisible, and it happens to be what the top of a night sky looks
    /// like anyway.
    private var sky: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: Self.notchBlend * 0.75),
                .init(color: skyColors[0], location: Self.skyTop),
                .init(color: skyColors[1], location: Self.waterline),
                .init(color: waterColor, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom)
    }

    /// The band that has to match the hardware cutout, as a fraction of panel height.
    private static let notchBlend: CGFloat = 0.20
    /// Where the sky has finished emerging from that black.
    private static let skyTop: CGFloat = 0.42
    /// Where the land stops and the harbour starts. Buildings stand on this line and are
    /// reflected below it.
    private static let waterline: CGFloat = 0.82

    /// Water is the sky, darker and colder — which is most of why a reflection reads as
    /// water rather than as a second city printed upside down.
    private var waterColor: Color {
        isDay
            ? Color(red: 0.07, green: 0.12, blue: 0.18)
            : Color(red: 0.01, green: 0.02, blue: 0.05)
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
        let waterY = size.height * Self.waterline
        // The rooftops. Buildings stand on the waterline and rise into the lower sky.
        let skylineTop = waterY - size.height * 0.30

        // Sky first, and kept out of both the black top band and the rooftops -- a star
        // beside the hardware cutout, or behind a building, is the one thing that would
        // give the whole illusion away.
        if isDay {
            if condition == .clear || condition == .cloudy { drawSun(&context, size, time) }
        } else {
            drawStars(&context, size, time,
                      from: size.height * Self.notchBlend, to: skylineTop)
            if condition == .clear || condition == .cloudy { drawMoon(&context, size) }
            drawShootingStar(&context, size, time)
        }

        // Clouds in every condition now, not only the overcast ones -- a sky with nothing
        // in it but stars reads as empty. Clear gets two high wisps, which is honest
        // enough: a clear night is a night without weather, not a night without air.
        drawClouds(&context, size, time)

        // Aircraft cross in front of the sky and behind the skyline, which is what makes
        // the city read as nearer than they are.
        if showCity {
            drawAircraft(&context, size, time, horizonY: skylineTop)
            drawCity(&context, size, time, waterY: waterY)
        }

        // Weather falls in front of everything, city and harbour included.
        switch condition {
        case .rain, .storm: drawPrecipitation(&context, size, time, isSnow: false)
        case .snow: drawPrecipitation(&context, size, time, isSnow: true)
        case .cloudy, .fog, .clear: break
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

    /// Star brightness, quantised into this many steps.
    ///
    /// Every star used to be its own `context.fill`, which is 46 draw calls a frame for
    /// 46 dots. Rounding each star's twinkle to one of six levels lets all the stars at
    /// a given brightness go into one path and one fill: six calls instead of forty-six,
    /// for a difference in brightness no eye resolves on a 2 pt dot. This is what pays
    /// for the city below.
    private static let starLevels = 6

    private func drawStars(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double,
        from top: CGFloat, to bottom: CGFloat
    ) {
        // Deterministic from the index, so the field is stable frame to frame without
        // storing any state.
        var buckets = [Path](repeating: Path(), count: Self.starLevels)

        for index in 0..<46 {
            let seed = Double(index)
            let x = fract(sin(seed * 12.9898) * 43758.5453) * size.width
            let y = top + fract(sin(seed * 78.233) * 24634.6345) * (bottom - top)
            let phase = fract(sin(seed * 39.425) * 11223.334) * 6.283
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(time * 1.4 + phase))
            let radius = 0.5 + fract(sin(seed * 4.771) * 3251.11) * 0.9

            let level = min(Int(twinkle * Double(Self.starLevels)), Self.starLevels - 1)
            buckets[level].addEllipse(in: CGRect(
                x: x, y: y, width: radius * 2, height: radius * 2))
        }

        for (level, path) in buckets.enumerated() where !path.isEmpty {
            let brightness = (Double(level) + 0.5) / Double(Self.starLevels)
            context.fill(path, with: .color(.white.opacity(0.9 * brightness * intensity)))
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

    /// Cloud cover by condition.
    ///
    /// Clear used to draw none at all, which left the sky reading as empty rather than as
    /// clear. Two faint wisps is honest: a clear night is a night without weather, not a
    /// night without air.
    private var cloudCover: (count: Int, opacity: Double) {
        switch condition {
        case .clear: (2, 0.07)
        case .cloudy: (4, 0.16)
        case .fog: (6, 0.20)
        case .rain, .storm: (4, 0.13)
        case .snow: (3, 0.12)
        }
    }

    private func drawClouds(_ context: inout GraphicsContext, _ size: CGSize, _ time: Double) {
        let cover = cloudCover
        for index in 0..<cover.count {
            let seed = Double(index)
            let speed = 0.006 + fract(sin(seed * 21.7) * 3312.9) * 0.008
            let x = fract(fract(sin(seed * 12.9) * 4471.3) + time * speed) * (size.width + 260) - 130
            // Kept inside the sky band: a cloud in the black top would put a grey smear
            // beside the hardware cutout, and one at the waterline would sit in the city.
            let band = Self.waterline - Self.notchBlend - 0.3
            let y = size.height * (Self.notchBlend + fract(sin(seed * 55.1) * 1129.7) * band)
            let width = size.height * (1.3 + fract(sin(seed * 8.3) * 771.1) * 1.1)

            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: width, height: width * 0.42)),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(cover.opacity * intensity), .clear]),
                    center: CGPoint(x: x + width / 2, y: y + width * 0.21),
                    startRadius: 0, endRadius: width * 0.5))
        }
    }

    // MARK: - City

    /// The skyline, drawn as a handful of paths rather than a pile of rectangles.
    ///
    /// Buildings are laid out left to right from a hash of their index, so the city is
    /// the same city every time the notch opens rather than reshuffling itself. Two
    /// depths: a far row that sits in the haze and a near row in near-silhouette, which
    /// is the cheapest way to get a skyline to read as having depth.
    ///
    /// Everything at one depth goes into one path and one fill, and the lit windows are
    /// grouped by brightness the same way the stars are. The whole city is about eight
    /// draw calls -- fewer than the star field cost before this commit.
    private func drawCity(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double, waterY: CGFloat
    ) {
        let baseY = waterY
        let depth = size.height * 0.30

        // The glow that makes a city read as a city at night: light thrown up into the
        // air above it, brightest right at the rooftops. Without it a dark silhouette on
        // a sky that is already black at the bottom is simply invisible.
        let glowColor = isDay
            ? Color(red: 0.62, green: 0.68, blue: 0.78)
            : Color(red: 1.0, green: 0.72, blue: 0.38)
        let glowRect = CGRect(
            x: -size.width * 0.1, y: baseY - depth * 1.5,
            width: size.width * 1.2, height: depth * 3)
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    glowColor.opacity((isDay ? 0.08 : 0.20) * intensity),
                    .clear,
                ]),
                center: CGPoint(x: size.width * 0.5, y: baseY),
                startRadius: 0, endRadius: depth * 1.5))

        // Far row: shorter, hazier, and offset so it never lines up with the near row.
        let far = skyline(
            width: size.width, baseY: baseY, maxHeight: depth * 0.62, seedOffset: 71.3,
            minWidth: 9, widthSpread: 13, gap: 5)
        context.fill(
            far.silhouette,
            with: .color(isDay
                ? Color(red: 0.13, green: 0.15, blue: 0.20).opacity(0.72 * intensity)
                : Color(red: 0.05, green: 0.06, blue: 0.11).opacity(0.88 * intensity)))

        let near = skyline(
            width: size.width, baseY: baseY, maxHeight: depth * 0.95, seedOffset: 12.7,
            minWidth: 14, widthSpread: 22, gap: 7)
        context.fill(
            near.silhouette,
            with: .color(isDay
                ? Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.86 * intensity)
                : Color.black.opacity(0.92 * intensity)))

        let windows = windowPaths(buildings: near.buildings, time: time)
        drawWindows(&context, paths: windows)
        let neon = neonSigns(buildings: near.buildings, time: time)
        drawNeon(&context, signs: neon)
        drawSpires(&context, buildings: near.buildings, time: time)
        drawHarbour(
            &context, size, time,
            waterY: waterY, skyline: near.silhouette, windows: windows, neon: neon)
    }

    /// The water, and the city standing in it.
    ///
    /// The reflection is the same geometry mirrored about the waterline rather than
    /// anything redrawn, so it costs a transform instead of a second skyline: one fill
    /// for the buildings, one per window brightness group, all of them faded downward by
    /// a gradient because a reflection loses definition with distance from what it
    /// reflects. What sells it as water rather than as an upside-down city is the last
    /// step -- horizontal ripples cut across the whole thing, breaking the verticals the
    /// way a harbour surface does.
    private func drawHarbour(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double,
        waterY: CGFloat, skyline: Path, windows: [Path], neon: [NeonSign]
    ) {
        let depth = size.height - waterY
        guard depth > 4 else { return }

        // Mirror about the waterline, and squash a little: a reflection seen at a low
        // angle across water is always shorter than the thing it reflects.
        let mirror = CGAffineTransform(translationX: 0, y: 2 * waterY)
            .scaledBy(x: 1, y: -0.72)

        // A copy of the context, clipped to the water, so nothing mirrored can climb
        // back out above the waterline.
        var surface = context
        surface.clip(to: Path(CGRect(x: 0, y: waterY, width: size.width, height: depth)))

        surface.fill(
            skyline.applying(mirror),
            with: .linearGradient(
                Gradient(colors: [
                    Color.black.opacity(0.55 * intensity),
                    Color.black.opacity(0.05 * intensity),
                ]),
                startPoint: CGPoint(x: 0, y: waterY),
                endPoint: CGPoint(x: 0, y: size.height)))

        let warm = Color(red: 1.0, green: 0.82, blue: 0.52)
        for (level, path) in windows.enumerated() where !path.isEmpty {
            surface.fill(
                path.applying(mirror),
                with: .linearGradient(
                    Gradient(colors: [
                        warm.opacity((0.20 + 0.12 * Double(level)) * intensity),
                        .clear,
                    ]),
                    startPoint: CGPoint(x: 0, y: waterY),
                    endPoint: CGPoint(x: 0, y: size.height)))
        }

        // Neon on water is the whole reason to put a city on a waterfront. Smeared wider
        // than the sign that casts it, because a small bright source on a moving surface
        // spreads rather than reflects.
        for sign in neon {
            let smear = sign.rect.insetBy(dx: -sign.rect.width * 0.3 - 2, dy: 0)
            surface.fill(
                Path(smear).applying(mirror),
                with: .linearGradient(
                    Gradient(colors: [
                        sign.color.opacity(0.42 * sign.brightness * intensity),
                        .clear,
                    ]),
                    startPoint: CGPoint(x: 0, y: waterY),
                    endPoint: CGPoint(x: 0, y: size.height)))
        }

        // The surface itself: a few slow bands of light lying across the water. One path,
        // one stroke, and they drift at different rates so the pattern never repeats
        // visibly.
        var ripples = Path()
        let count = max(Int(depth / 5), 3)
        for index in 0..<count {
            let seed = Double(index)
            let base = waterY + depth * CGFloat(Double(index) / Double(count))
            let sway = sin(time * (0.35 + fract(sin(seed * 21.3) * 3312.9) * 0.4) + seed)
            let inset = size.width * CGFloat(0.04 + fract(sin(seed * 8.7) * 4471.3) * 0.3)
            let y = base + CGFloat(sway) * 0.8

            ripples.move(to: CGPoint(x: inset, y: y))
            ripples.addLine(to: CGPoint(x: size.width - inset * 0.6, y: y))
        }
        context.stroke(
            ripples,
            with: .color(.white.opacity((isDay ? 0.10 : 0.07) * intensity)),
            style: StrokeStyle(lineWidth: 0.7, lineCap: .round))

        // A bright line right at the waterline, where the city's light meets the water.
        var edge = Path()
        edge.move(to: CGPoint(x: 0, y: waterY))
        edge.addLine(to: CGPoint(x: size.width, y: waterY))
        context.stroke(
            edge,
            with: .color(Color(red: 1.0, green: 0.78, blue: 0.48)
                .opacity((isDay ? 0.10 : 0.18) * intensity)),
            style: StrokeStyle(lineWidth: 0.8))
    }

    private struct Skyline {
        var silhouette = Path()
        var buildings: [CGRect] = []
    }

    /// Tiles buildings across the width from index hashes. Deterministic, so the skyline
    /// is stable across frames and across launches; capped so a narrow panel cannot spin
    /// the loop.
    private func skyline(
        width: CGFloat, baseY: CGFloat, maxHeight: CGFloat, seedOffset: Double,
        minWidth: CGFloat, widthSpread: CGFloat, gap: CGFloat
    ) -> Skyline {
        var result = Skyline()
        var x: CGFloat = -minWidth
        var index = 0

        while x < width + minWidth && index < 40 {
            let seed = Double(index) + seedOffset
            let buildingWidth = minWidth + CGFloat(fract(sin(seed * 12.9898) * 43758.5453)) * widthSpread
            let height = maxHeight * (0.3 + CGFloat(fract(sin(seed * 78.233) * 24634.6345)) * 0.7)
            let rect = CGRect(x: x, y: baseY - height, width: buildingWidth, height: height)

            result.silhouette.addRect(rect)
            result.buildings.append(rect)

            x += buildingWidth + CGFloat(fract(sin(seed * 33.71) * 9134.2)) * gap
            index += 1
        }
        return result
    }

    /// Lit windows, in three brightness groups so the whole city costs three fills.
    ///
    /// A window's state comes from a hash of its position plus a slow phase, so most sit
    /// still while a few fade up or down over tens of seconds -- somebody getting home,
    /// somebody going to bed. Fast flicker would read as a broken display.
    private func drawWindows(_ context: inout GraphicsContext, paths: [Path]) {
        // Warm, and never white: a white window in a black notch reads as a dead pixel.
        let warm = Color(red: 1.0, green: 0.84, blue: 0.55)
        for (level, path) in paths.enumerated() where !path.isEmpty {
            let brightness = 0.30 + 0.28 * Double(level)
            context.fill(path, with: .color(warm.opacity(brightness * intensity)))
        }
    }

    /// Built once and used twice — once for the windows and once for their reflection.
    private func windowPaths(buildings: [CGRect], time: Double) -> [Path] {
        // Daylight leaves windows unlit: at noon a lit office window is invisible anyway,
        // and drawing them is work for nothing.
        guard !isDay else { return [] }

        let cell: CGFloat = 4.2
        let pane = CGSize(width: 1.6, height: 2.1)
        var buckets = [Path](repeating: Path(), count: 3)

        for (buildingIndex, building) in buildings.enumerated() {
            let columns = max(Int((building.width - 3) / cell), 1)
            let rows = max(Int((building.height - 4) / cell), 1)
            guard rows > 0, columns > 0 else { continue }

            let inset = (building.width - CGFloat(columns) * cell) / 2

            for row in 0..<min(rows, 14) {
                for column in 0..<min(columns, 6) {
                    let seed = Double(buildingIndex) * 37.0 + Double(row) * 7.0 + Double(column)
                    let lit = fract(sin(seed * 45.164) * 21947.3)
                    guard lit > 0.55 else { continue }

                    // Most windows hold steady; the phase only matters for the few whose
                    // hash puts them near a transition.
                    let phase = fract(sin(seed * 91.377) * 7712.9) * 6.283
                    let breath = 0.5 + 0.5 * sin(time * 0.22 + phase)
                    let level = min(Int((lit - 0.55) / 0.45 * 2 + breath), 2)

                    buckets[level].addRect(CGRect(
                        x: building.minX + inset + CGFloat(column) * cell + 1,
                        y: building.minY + 3 + CGFloat(row) * cell,
                        width: pane.width, height: pane.height))
                }
            }
        }
        return buckets
    }

    // MARK: Neon

    /// One sign: where it is, what colour it burns, and how brightly this frame.
    private struct NeonSign {
        var rect: CGRect
        var color: Color
        var brightness: Double
        var vertical: Bool
    }

    /// The colours neon actually comes in. Saturated, because a desaturated neon sign is
    /// just a lamp, and this is the one place in the scene allowed to be loud — it sits
    /// behind frosted glass and reads as a colour cast rather than as a shape.
    private static let neonPalette: [Color] = [
        Color(red: 1.00, green: 0.24, blue: 0.60),   // hot pink
        Color(red: 0.32, green: 0.92, blue: 1.00),   // cyan
        Color(red: 1.00, green: 0.66, blue: 0.18),   // amber
        Color(red: 0.70, green: 0.42, blue: 1.00),   // violet
        Color(red: 0.36, green: 1.00, blue: 0.64),   // green
    ]

    /// Signs on about a third of the near buildings, horizontal along a facade or running
    /// down a narrow one, the way they actually hang.
    ///
    /// Most burn steady with a slight buzz. A few have the stutter of a tube on its way
    /// out — brief, irregular, and only on the ones whose hash says so, because a whole
    /// skyline flickering in unison reads as a rendering fault rather than as a city.
    private func neonSigns(buildings: [CGRect], time: Double) -> [NeonSign] {
        guard !isDay else { return [] }
        var signs: [NeonSign] = []

        for (index, building) in buildings.enumerated() {
            let seed = Double(index) * 13.77
            let pick = fract(sin(seed * 27.31) * 6641.9)
            guard pick > 0.66, signs.count < 5 else { continue }

            let color = Self.neonPalette[
                Int(fract(sin(seed * 55.9) * 3319.1) * Double(Self.neonPalette.count))
                    % Self.neonPalette.count]

            // A steady tube still moves a little; this is the hum, not a blink.
            let phase = fract(sin(seed * 71.9) * 8812.3) * 6.283
            var brightness = 0.86 + 0.14 * (0.5 + 0.5 * sin(time * 3.1 + phase))

            // The failing ones: dark for a fraction of a second, every several seconds.
            if fract(sin(seed * 44.3) * 2217.7) > 0.62 {
                let period = 5.0 + fract(sin(seed * 19.4) * 5514.2) * 7.0
                let cycle = (time + phase).truncatingRemainder(dividingBy: period)
                if cycle < 0.09 || (cycle > 0.17 && cycle < 0.23) { brightness = 0.18 }
            }

            let vertical = building.width < 19 && building.height > 26
            let rect: CGRect
            if vertical {
                rect = CGRect(
                    x: building.midX - 1.3,
                    y: building.minY + building.height * 0.16,
                    width: 2.6,
                    height: min(building.height * 0.46, 22))
            } else {
                let width = building.width * 0.62
                rect = CGRect(
                    x: building.midX - width / 2,
                    y: building.minY + building.height * CGFloat(0.16 + pick * 0.3),
                    width: width,
                    height: 2.6)
            }

            signs.append(NeonSign(
                rect: rect, color: color, brightness: brightness, vertical: vertical))
        }
        return signs
    }

    /// Tube plus bloom. The bloom is most of the effect — a neon sign is a light source,
    /// and a light source with hard edges and no spill reads as a sticker.
    private func drawNeon(_ context: inout GraphicsContext, signs: [NeonSign]) {
        for sign in signs {
            let bloom = sign.rect.insetBy(
                dx: -sign.rect.width * (sign.vertical ? 3.4 : 0.42) - 5,
                dy: -sign.rect.height * (sign.vertical ? 0.42 : 3.4) - 5)

            context.fill(
                Path(ellipseIn: bloom),
                with: .radialGradient(
                    Gradient(colors: [
                        sign.color.opacity(0.32 * sign.brightness * intensity),
                        .clear,
                    ]),
                    center: CGPoint(x: bloom.midX, y: bloom.midY),
                    startRadius: 0,
                    endRadius: max(bloom.width, bloom.height) / 2))

            context.fill(
                Path(roundedRect: sign.rect, cornerRadius: 1.3),
                with: .color(sign.color.opacity(0.92 * sign.brightness * intensity)))
        }
    }

    /// Masts on the tallest buildings, each with the red obstruction light that every
    /// real skyline blinks at aircraft. They blink out of step, because real ones do.
    private func drawSpires(
        _ context: inout GraphicsContext, buildings: [CGRect], time: Double
    ) {
        var masts = Path()
        var lights = Path()

        for (index, building) in buildings.enumerated() {
            let seed = Double(index) * 5.31
            guard fract(sin(seed * 61.7) * 4517.9) > 0.72 else { continue }

            let x = building.midX
            let top = building.minY - building.height * 0.16
            masts.move(to: CGPoint(x: x, y: building.minY))
            masts.addLine(to: CGPoint(x: x, y: top))

            // Roughly one second on, one and a half off, offset per mast.
            let phase = fract(sin(seed * 23.9) * 8821.4) * 2.5
            guard (time + phase).truncatingRemainder(dividingBy: 2.5) < 1.0 else { continue }
            lights.addEllipse(in: CGRect(x: x - 1.1, y: top - 1.1, width: 2.2, height: 2.2))
        }

        context.stroke(
            masts,
            with: .color(Color.black.opacity(0.8 * intensity)),
            style: StrokeStyle(lineWidth: 0.8))
        context.fill(
            lights,
            with: .color(Color(red: 1.0, green: 0.25, blue: 0.22).opacity(0.85 * intensity)))
    }

    /// Aircraft crossing the sky: a body, a wing, and a beacon that blinks.
    ///
    /// Two lanes, each carrying one aircraft at a time on its own long cycle, so mostly
    /// there is one in the sky and occasionally two. They cross in about half a minute --
    /// slow enough that noticing one feels like noticing something rather than watching a
    /// screensaver.
    private func drawAircraft(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double, horizonY: CGFloat
    ) {
        for lane in 0..<2 {
            let seed = Double(lane) * 17.3
            let period = 46.0 + fract(sin(seed * 12.4) * 3391.7) * 26.0
            let crossing = 30.0
            let cycle = (time + fract(sin(seed * 71.1) * 5527.3) * period)
                .truncatingRemainder(dividingBy: period)
            guard cycle < crossing else { continue }

            let progress = cycle / crossing
            let flight = floor((time + seed) / period)
            // Half the flights go the other way.
            let eastbound = fract(sin(flight * 44.7 + seed) * 6612.1) > 0.5
            let x = size.width * CGFloat(eastbound ? progress : 1 - progress)
            let y = horizonY * CGFloat(0.16 + fract(sin(flight * 88.3 + seed) * 2214.9) * 0.5)
            let heading: CGFloat = eastbound ? 1 : -1

            // Fades at both ends so it enters and leaves rather than popping.
            let fade = min(1, sin(progress * .pi) * 3)
            let body = Color.white.opacity(0.55 * fade * intensity)

            var shape = Path()
            shape.move(to: CGPoint(x: x - 3 * heading, y: y))
            shape.addLine(to: CGPoint(x: x + 3 * heading, y: y))
            shape.move(to: CGPoint(x: x - 0.5 * heading, y: y - 1.6))
            shape.addLine(to: CGPoint(x: x - 0.5 * heading, y: y + 1.6))
            context.stroke(shape, with: .color(body), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))

            // The strobe: brief, and about once a second, the way an anti-collision light
            // actually behaves.
            guard time.truncatingRemainder(dividingBy: 1.0) < 0.12 else { continue }
            context.fill(
                Path(ellipseIn: CGRect(x: x + 2.4 * heading - 1, y: y - 1, width: 2, height: 2)),
                with: .color(.white.opacity(0.9 * fade * intensity)))
        }
    }

    /// Fractional part — the cheap deterministic hash these scenes are built on.
    private func fract(_ value: Double) -> Double { value - floor(value) }
}
