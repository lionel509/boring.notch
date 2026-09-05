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
    /// The album art's average colour, which the neon takes its hue from.
    let accent: NSColor

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
                // A wash when the sky was only a gradient; a coat now that it is a
                // place.
                //
                // 18% was right when this drew nothing but a colour ramp whose whole job
                // was to tint the glass — at 55% it fought the album art's own lighting
                // effect and came out muddy. But a scene at 18% is not a scene: with the
                // desktop at 82%, a warm wallpaper washed straight through the sky and
                // read as a red haze hanging over the city. Now that there is a skyline,
                // a harbour and a light show back there, the sky has to win, and the
                // desktop's job drops to what it was always best at — a bit of real light
                // from behind, rather than the picture itself.
                sky.opacity(showCity ? 0.72 : 0.18)
            } else {
                sky
            }

            TimelineView(.animation(minimumInterval: frameInterval, paused: false)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }

            // Opaque, and above everything else in the stack.
            //
            // Making the sky gradient start at black was not enough: with the desktop
            // showing through, the sky is only an 18% tint over the blur, so "black" came
            // out as the wallpaper at 82%. The band the hardware cutout sits in has to be
            // painted, not tinted — it is the one part of this panel whose job is to be
            // the same colour as a hole in the display.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: Self.notchBlend * 0.85),
                    .init(color: .black.opacity(0), location: Self.notchBlend * 1.7),
                ],
                startPoint: .top,
                endPoint: .bottom)
                .allowsHitTesting(false)

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
            //
            // Halved after the sky went opaque. These numbers were set while the desktop
            // was still supplying 82% of every pixel — a bright wallpaper behind grey
            // text needed a heavy coat. The sky at 72% is already dark, so the same scrim
            // on top of it stacked into a night with the lights turned down: two fixes,
            // each right on its own, crushing the city between them.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.10), location: 0),
                    .init(color: .black.opacity(0.13), location: 0.45),
                    .init(color: .black.opacity(0.24), location: 0.78),
                    .init(color: .black.opacity(0.28), location: 1),
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

    /// How far into the night it is: 0 in full daylight, 1 once the sun is properly
    /// down, ramping continuously through dusk and dawn.
    ///
    /// Everything in the city used to key off `isDay`, which is a boolean — so the whole
    /// skyline, every sign, both searchlights and the laser rig came on in the same
    /// frame, at whatever minute the weather service decided the sun had set. Real cities
    /// light up through dusk, and they start before sunset: lights come on when the sun
    /// gets *low*, not when it disappears. This drives every lit thing down there.
    private var nightfall: Double {
        guard isDay else { return 1 }
        // 0 at sunrise and sunset, 1 at noon.
        let elevation = sin(min(max(sunProgress, 0), 1) * .pi)
        // The last stretch before the horizon is the whole ramp.
        return min(max((0.24 - elevation) / 0.24, 0), 1)
    }

    /// Opacity for anything that is only lit after dark.
    private var litIntensity: Double { intensity * nightfall }

    /// Where anything that rises and sets touches down: the rooftops.
    private static func horizonY(_ size: CGSize) -> CGFloat {
        size.height * waterline - size.height * 0.22
    }

    /// How far above that horizon the sky goes before it runs into the black band.
    private static func skyReach(_ size: CGSize) -> CGFloat {
        horizonY(size) - size.height * notchBlend * 1.15
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
            default: return [Color(red: 0.05, green: 0.09, blue: 0.24), Color(red: 0.02, green: 0.03, blue: 0.09)]
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
        if isDay, condition == .clear || condition == .cloudy {
            drawSun(&context, size, time)
        }

        // Stars fade up through dusk rather than appearing all at once, and the moon is
        // drawn whenever it is actually above the horizon — including in daylight, where
        // a real one is often perfectly visible and this one used to be suppressed.
        if nightfall > 0.02 {
            drawStars(&context, size, time,
                      from: size.height * Self.notchBlend, to: skylineTop)
        }
        if condition == .clear || condition == .cloudy { drawMoon(&context, size) }
        // A streak only reads against a dark sky.
        if nightfall > 0.55 { drawShootingStar(&context, size, time) }

        // Clouds in every condition now, not only the overcast ones -- a sky with nothing
        // in it but stars reads as empty. Clear gets two high wisps, which is honest
        // enough: a clear night is a night without weather, not a night without air.
        drawClouds(&context, size, time)

        // Aircraft cross in front of the sky and behind the skyline, which is what makes
        // the city read as nearer than they are.
        if showCity {
            // The skyline is built before anything that has to stand on it. Beams used to
            // start at a fixed line a few points above the rooftops, which put them in
            // mid-air between buildings — they now come off the roof of an actual one.
            let city = cityLayers(size: size, waterY: waterY)

            drawAircraft(&context, size, time, horizonY: skylineTop)
            // Beams before the buildings, so the silhouette drawn next cuts off their
            // feet: that is what puts a beam in the city rather than on top of it.
            drawSearchlights(&context, size, time,
                             roofs: city.near.buildings,
                             ceiling: size.height * Self.notchBlend)
            drawLasers(&context, size, time,
                       roofs: city.near.buildings,
                       ceiling: size.height * Self.notchBlend)
            drawCity(&context, size, time, waterY: waterY, city: city)
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
            // Rising out of the skyline rather than out of the bottom of the panel.
            // Before the city existed the panel's floor was the horizon; now the horizon
            // is the rooftops, and a sun climbing out of the water below them was the
            // one thing in the scene that could not happen.
            y: Self.horizonY(size) - CGFloat(arc) * Self.skyReach(size))
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
            y: Self.horizonY(size) - CGFloat(arc) * Self.skyReach(size) * 0.86)
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

        // Faint but present in daylight — a daytime moon is a real thing, and hiding it
        // was the boolean talking.
        let daylight = 0.28 + 0.72 * nightfall
        context.fill(
            disc,
            with: .color(Color(red: 0.96, green: 0.96, blue: 0.92)
                .opacity(0.82 * visibility * intensity * daylight)))
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
            context.fill(path, with: .color(.white.opacity(0.9 * brightness * litIntensity)))
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
    /// The two rows of buildings, built once per frame and used by everything that has
    /// to know where a roof is.
    private func cityLayers(size: CGSize, waterY: CGFloat) -> (far: Skyline, near: Skyline) {
        let depth = size.height * 0.30
        return (
            far: skyline(
                width: size.width, baseY: waterY, maxHeight: depth * 0.62, seedOffset: 71.3,
                minWidth: 9, widthSpread: 13, gap: 5),
            near: skyline(
                width: size.width, baseY: waterY, maxHeight: depth * 0.95, seedOffset: 12.7,
                minWidth: 14, widthSpread: 22, gap: 7))
    }

    /// The tallest building whose centre falls in a given slice of the width, so a beam
    /// lands on a landmark rather than on whatever happens to be under that x.
    private func tallestBuilding(
        in buildings: [CGRect], from: CGFloat, to: CGFloat
    ) -> CGRect? {
        buildings
            .filter { $0.midX >= from && $0.midX <= to }
            .min { $0.minY < $1.minY }
    }

    private func drawCity(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double, waterY: CGFloat,
        city: (far: Skyline, near: Skyline)
    ) {
        let baseY = waterY
        let depth = size.height * 0.30

        // The glow that makes a city read as a city at night: light thrown up into the
        // air above it, brightest right at the rooftops. Without it a dark silhouette on
        // a sky that is already black at the bottom is simply invisible.
        // Cold and dim by day, warm and strong by night, mixed continuously between.
        let glowColor = Color(
            red: 0.62 + 0.38 * nightfall,
            green: 0.68 + 0.04 * nightfall,
            blue: 0.78 - 0.40 * nightfall)
        let glowRect = CGRect(
            x: -size.width * 0.1, y: baseY - depth * 1.5,
            width: size.width * 1.2, height: depth * 3)
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    glowColor.opacity((0.10 + 0.20 * nightfall) * intensity),
                    .clear,
                ]),
                center: CGPoint(x: size.width * 0.5, y: baseY),
                startRadius: 0, endRadius: depth * 1.5))

        // Far row: shorter, hazier, and offset so it never lines up with the near row.
        context.fill(
            city.far.silhouette,
            with: .color(isDay
                ? Color(red: 0.13, green: 0.15, blue: 0.20).opacity(0.72 * intensity)
                : Color(red: 0.05, green: 0.06, blue: 0.11).opacity(0.88 * intensity)))

        let near = city.near
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
        //
        // The squash has to be paid for in the translation. `scaledBy` applies the scale
        // *before* the existing transform, so a plain 2 * waterY translation only mirrors
        // correctly at a scale of exactly -1 — with the 0.72 squash it left every
        // reflection sitting a fifth of the waterline too low, which is why the neon
        // looked like it belonged to no building in particular. Solving
        // y' = waterY - 0.72 * (y - waterY) gives the factor below.
        let squash: CGFloat = 0.72
        let mirror = CGAffineTransform(translationX: 0, y: waterY * (1 + squash))
            .scaledBy(x: 1, y: -squash)

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
                        warm.opacity((0.20 + 0.12 * Double(level)) * litIntensity),
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
                        sign.color.opacity(0.42 * sign.brightness * litIntensity),
                        .clear,
                    ]),
                    startPoint: CGPoint(x: 0, y: waterY),
                    endPoint: CGPoint(x: 0, y: size.height)))
        }

        drawPromenade(&context, size, time, waterY: waterY)
        drawBoats(&context, size, time, waterY: waterY, depth: depth)

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
            with: .color(.white.opacity((0.10 - 0.03 * nightfall) * intensity)),
            style: StrokeStyle(lineWidth: 0.7, lineCap: .round))

        // A bright line right at the waterline, where the city's light meets the water.
        var edge = Path()
        edge.move(to: CGPoint(x: 0, y: waterY))
        edge.addLine(to: CGPoint(x: size.width, y: waterY))
        context.stroke(
            edge,
            with: .color(Color(red: 1.0, green: 0.78, blue: 0.48)
                .opacity((0.10 + 0.08 * nightfall) * intensity)),
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
            let brightness = 0.42 + 0.30 * Double(level)
            context.fill(path, with: .color(warm.opacity(brightness * litIntensity)))
        }
    }

    /// Built once and used twice — once for the windows and once for their reflection.
    private func windowPaths(buildings: [CGRect], time: Double) -> [Path] {
        // Full daylight leaves windows unlit: at noon a lit office window is invisible
        // anyway, and drawing them is work for nothing. They come up through dusk.
        guard nightfall > 0.05 else { return [] }

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

    // MARK: Searchlights

    /// Beams thrown up out of the city, sweeping.
    ///
    /// This is the thing that makes a skyline read as *nightlife* rather than as a place
    /// where people work late — Tianjin, Shanghai, a Manhattan rooftop, any of them at
    /// midnight. Each beam is a wedge from a rooftop widening as it climbs, fading out
    /// before it reaches the black band so it never runs into the hardware cutout, and
    /// swinging on its own slow period so the three never sweep together.
    ///
    /// Three fills. The expensive-looking part of this scene is the cheap part.
    private func drawSearchlights(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double,
        roofs: [CGRect], ceiling: CGFloat
    ) {
        // A beam needs a dark sky to be a beam. In half-light it is a smudge, so these
        // wait for most of the way into the night rather than coming on at dusk.
        guard nightfall > 0.6 else { return }

        for index in 0..<3 {
            let seed = Double(index) * 9.13
            // One per third of the skyline, on the tallest roof in that third.
            let slice = size.width / 3
            guard let host = tallestBuilding(
                in: roofs, from: slice * CGFloat(index), to: slice * CGFloat(index + 1))
            else { continue }

            // Slightly off centre, because a rig sits on a roof rather than in the middle
            // of one.
            let origin = CGPoint(
                x: host.midX + (CGFloat(fract(sin(seed * 44.1) * 1129.7)) - 0.5) * host.width * 0.5,
                y: host.minY + 1)

            // Slow, and each on its own period so they drift in and out of phase rather
            // than sweeping in formation.
            let speed = 0.16 + fract(sin(seed * 7.7) * 1123.4) * 0.13
            let angle = sin(time * speed + Double(index) * 2.3) * 0.62

            let reach = origin.y - ceiling * 0.5
            let tip = CGPoint(
                x: origin.x + CGFloat(sin(angle)) * reach,
                y: origin.y - reach * CGFloat(cos(angle)))
            let spread = reach * 0.13

            // Perpendicular to the beam, so the wedge widens squarely rather than
            // shearing as it swings.
            let normal = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))

            var wedge = Path()
            wedge.move(to: CGPoint(x: origin.x - normal.x * 1.6, y: origin.y - normal.y * 1.6))
            wedge.addLine(to: CGPoint(x: origin.x + normal.x * 1.6, y: origin.y + normal.y * 1.6))
            wedge.addLine(to: CGPoint(x: tip.x + normal.x * spread, y: tip.y + normal.y * spread))
            wedge.addLine(to: CGPoint(x: tip.x - normal.x * spread, y: tip.y - normal.y * spread))
            wedge.closeSubpath()

            // Mostly white with a wash of the sign colours, the way a real beam picks up
            // whatever is in the air under it.
            let tint = neonPalette[index % neonPalette.count]
            context.fill(
                wedge,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.20 * litIntensity),
                        tint.opacity(0.10 * litIntensity),
                        .clear,
                    ]),
                    startPoint: origin, endPoint: tip))
        }
    }

    /// The waterfront itself: a broken line of light along the quay.
    ///
    /// Every neon city on water has this and it is most of why the photographs look the
    /// way they do — signs and windows are up in the buildings, but the strip right at
    /// the water is bars and restaurants and streetlights, and it is the brightest line
    /// in the frame. Drawn as segments rather than a rule, because a continuous line
    /// reads as a light fitting and a broken one reads as a street.
    private func drawPromenade(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double, waterY: CGFloat
    ) {
        // Streetlights come on first of anything here, which is true of streetlights.
        guard nightfall > 0.02 else { return }
        let palette = neonPalette

        var x: CGFloat = -6
        var index = 0
        while x < size.width + 6 && index < 26 {
            let seed = Double(index) * 6.41
            let width = 6 + CGFloat(fract(sin(seed * 12.9) * 4471.3)) * 16
            let gap = 3 + CGFloat(fract(sin(seed * 44.7) * 2217.7)) * 9

            // Most of the strip is warm streetlight; a third of it is a sign.
            let pick = fract(sin(seed * 71.9) * 8812.3)
            let color = pick > 0.66
                ? palette[Int(pick * Double(palette.count)) % palette.count]
                : Color(red: 1.0, green: 0.80, blue: 0.48)
            let flicker = 0.78 + 0.22 * (0.5 + 0.5 * sin(time * 1.7 + Double(index)))

            let bar = CGRect(x: x, y: waterY - 2.2, width: width, height: 1.6)
            context.fill(
                Path(ellipseIn: bar.insetBy(dx: -width * 0.18, dy: -3.4)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.22 * flicker * litIntensity), .clear]),
                    center: CGPoint(x: bar.midX, y: bar.midY),
                    startRadius: 0, endRadius: width * 0.7))
            context.fill(
                Path(roundedRect: bar, cornerRadius: 0.8),
                with: .color(color.opacity(0.72 * flicker * litIntensity)))

            x += width + gap
            index += 1
        }
    }

    /// A laser fan, off a rooftop.
    ///
    /// The counterpart to the searchlights rather than more of them: a searchlight is a
    /// wide soft wedge of lit air, a laser is a hard thin line that does not spread. Both
    /// at once is what a skyline looks like on a night when something is on — the beams
    /// are the venue, the lasers are the show.
    ///
    /// Five lines from one point, fanning and sweeping together, because a laser rig is
    /// one machine. They pulse as a set for the same reason.
    private func drawLasers(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double,
        roofs: [CGRect], ceiling: CGFloat
    ) {
        guard nightfall > 0.7 else { return }

        // On for a while, off for longer. A rig that never stops is wallpaper.
        let period = 26.0
        let cycle = time.truncatingRemainder(dividingBy: period)
        guard cycle < 9.0 else { return }
        let envelope = min(1, min(cycle, 9.0 - cycle) / 1.4)

        // The rig goes on the tallest roof in the right half — the building that would
        // actually be hosting the party.
        guard let host = tallestBuilding(in: roofs, from: size.width * 0.5, to: size.width)
        else { return }
        let origin = CGPoint(x: host.midX, y: host.minY + 1)
        let reach = origin.y - ceiling * 0.4
        let sweep = sin(time * 0.55) * 0.42
        let spread = 0.20 + 0.10 * sin(time * 0.31)
        let palette = neonPalette

        for index in 0..<5 {
            let angle = sweep + (Double(index) - 2) * spread
            let tip = CGPoint(
                x: origin.x + CGFloat(sin(angle)) * reach,
                y: origin.y - CGFloat(cos(angle)) * reach)

            var beam = Path()
            beam.move(to: origin)
            beam.addLine(to: tip)

            let color = palette[index % palette.count]
            // Fades along its length rather than ending: a laser you can see is dust in
            // the air, and there is less of it higher up.
            context.stroke(
                beam,
                with: .linearGradient(
                    Gradient(colors: [
                        color.opacity(0.55 * envelope * litIntensity),
                        color.opacity(0.16 * envelope * litIntensity),
                        .clear,
                    ]),
                    startPoint: origin, endPoint: tip),
                style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }
    }

    // MARK: Harbour traffic

    /// Boats crossing the water: a hull, a warm cabin light, a wake, and the light's
    /// smear on the surface behind it.
    ///
    /// Slow — a minute and a half to cross — and small, because the scale of the thing is
    /// what says how far away the far shore is. Two of them on separate cycles, so
    /// sometimes there are two and sometimes the harbour is empty, which is what a
    /// harbour looks like.
    private func drawBoats(
        _ context: inout GraphicsContext, _ size: CGSize, _ time: Double,
        waterY: CGFloat, depth: CGFloat
    ) {
        for index in 0..<3 {
            let seed = Double(index) * 23.9
            let period = 38.0 + fract(sin(seed * 11.3) * 6613.1) * 26.0
            let crossing = 34.0
            let cycle = (time + fract(sin(seed * 63.7) * 2219.9) * period)
                .truncatingRemainder(dividingBy: period)
            guard cycle < crossing else { continue }

            let progress = cycle / crossing
            let voyage = floor((time + seed) / period)
            let eastbound = fract(sin(voyage * 51.3 + seed) * 7741.7) > 0.5
            let heading: CGFloat = eastbound ? 1 : -1

            // Further out means higher in the band and smaller.
            let lane = CGFloat(0.18 + fract(sin(voyage * 29.1 + seed) * 3317.3) * 0.45)
            let y = waterY + depth * lane
            let scale = 0.6 + lane * 0.9
            let x = size.width * CGFloat(eastbound ? progress : 1 - progress)
            let fade = min(1, sin(progress * .pi) * 4) * intensity

            let length = 13 * scale
            let height = 3.0 * scale

            // Hull: flat deck, curved underside, a stub of a wheelhouse.
            var hull = Path()
            hull.move(to: CGPoint(x: x - length / 2, y: y))
            hull.addLine(to: CGPoint(x: x + length / 2, y: y))
            hull.addQuadCurve(
                to: CGPoint(x: x - length / 2, y: y),
                control: CGPoint(x: x, y: y + height * 1.8))
            hull.closeSubpath()
            hull.addRect(CGRect(
                x: x - length * 0.1 * heading, y: y - height * 1.5,
                width: length * 0.26, height: height * 1.5))

            context.fill(hull, with: .color(.black.opacity(0.82 * fade)))

            // Cabin light, and its reflection running down the water underneath it.
            let lightPoint = CGPoint(x: x + length * 0.06 * heading, y: y - height * 1.5)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: lightPoint.x - 1.1 * scale, y: lightPoint.y - 1.1 * scale,
                    width: 2.2 * scale, height: 2.2 * scale)),
                with: .color(Color(red: 1.0, green: 0.86, blue: 0.6)
                    .opacity(0.9 * fade * (0.2 + 0.8 * nightfall))))
            context.fill(
                Path(CGRect(
                    x: lightPoint.x - 0.7 * scale, y: y,
                    width: 1.4 * scale, height: depth * 0.3)),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 1.0, green: 0.82, blue: 0.55)
                            .opacity(0.34 * fade * (0.15 + 0.85 * nightfall)),
                        .clear,
                    ]),
                    startPoint: CGPoint(x: 0, y: y),
                    endPoint: CGPoint(x: 0, y: y + depth * 0.3)))

            // Wake: two short strokes trailing astern, the near one longer.
            var wake = Path()
            for step in 0..<2 {
                let trail = length * (1.4 + CGFloat(step) * 1.5)
                let drop = height * (0.5 + CGFloat(step) * 0.7)
                wake.move(to: CGPoint(x: x - length / 2 * heading, y: y + drop))
                wake.addLine(to: CGPoint(x: x - trail * heading, y: y + drop))
            }
            context.stroke(
                wake,
                with: .color(.white.opacity(0.16 * fade)),
                style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }
    }

    // MARK: Neon

    /// One sign: where it is, what colour it burns, and how brightly this frame.
    private struct NeonSign {
        var rect: CGRect
        var color: Color
        var brightness: Double
        var kind: Kind

        /// The four shapes a sign actually takes on a real skyline.
        enum Kind {
            /// A blade hung down the corner of a narrow tower.
            case blade
            /// A band across a facade.
            case band
            /// A billboard standing on the roof, on legs. The one that says Tianjin
            /// rather than Anywhere.
            case rooftop
            /// A whole storey lit in one colour — the bar floor, the restaurant floor.
            case storey
        }
    }

    /// The colours neon comes in when nothing is playing. Saturated, because a
    /// desaturated neon sign is just a lamp, and this is the one place in the scene
    /// allowed to be loud — it sits behind frosted glass and reads as a colour cast
    /// rather than as a shape.
    private static let defaultNeon: [Color] = [
        Color(red: 1.00, green: 0.24, blue: 0.60),   // hot pink
        Color(red: 0.32, green: 0.92, blue: 1.00),   // cyan
        Color(red: 1.00, green: 0.66, blue: 0.18),   // amber
        Color(red: 0.70, green: 0.42, blue: 1.00),   // violet
        Color(red: 0.36, green: 1.00, blue: 0.64),   // green
    ]

    /// The city's neon, tuned to whatever is playing.
    ///
    /// Not the album colour five times over — a skyline in one flat hue reads as a
    /// filter laid over the scene rather than as signs. This takes the artwork's *hue*
    /// and fans out around it, the way a real street's signs are all different and still
    /// obviously belong to the same street. Saturation and brightness are forced up
    /// regardless of the artwork, because neon is neon.
    ///
    /// Falls back to the fixed palette when the artwork has no hue to borrow — a
    /// black-and-white sleeve would otherwise hand the city five grey signs.
    private var neonPalette: [Color] {
        guard let rgb = accent.usingColorSpace(.deviceRGB) else { return Self.defaultNeon }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.16, brightness > 0.10 else { return Self.defaultNeon }

        // Spread around the artwork's hue: two neighbours either side and a complement,
        // which is what keeps a street from looking monochrome.
        return [0.0, 0.07, -0.09, 0.17, 0.45].map { offset in
            Color(hue: Double((hue + CGFloat(offset)).truncatingRemainder(dividingBy: 1) + 1)
                    .truncatingRemainder(dividingBy: 1),
                  saturation: 0.82,
                  brightness: 0.98)
        }
    }

    /// Signs on about a third of the near buildings, horizontal along a facade or running
    /// down a narrow one, the way they actually hang.
    ///
    /// Most burn steady with a slight buzz. A few have the stutter of a tube on its way
    /// out — brief, irregular, and only on the ones whose hash says so, because a whole
    /// skyline flickering in unison reads as a rendering fault rather than as a city.
    private func neonSigns(buildings: [CGRect], time: Double) -> [NeonSign] {
        // Signs go on before the windows do — a bar's sign is lit while it is still
        // light out, which is exactly what makes early evening look like early evening.
        guard nightfall > 0.02 else { return [] }
        var signs: [NeonSign] = []

        for (index, building) in buildings.enumerated() {
            let seed = Double(index) * 13.77
            let pick = fract(sin(seed * 27.31) * 6641.9)
            guard pick > 0.30, signs.count < 9 else { continue }

            let color = neonPalette[
                Int(fract(sin(seed * 55.9) * 3319.1) * Double(neonPalette.count))
                    % neonPalette.count]

            // A steady tube still moves a little; this is the hum, not a blink.
            let phase = fract(sin(seed * 71.9) * 8812.3) * 6.283
            var brightness = 0.86 + 0.14 * (0.5 + 0.5 * sin(time * 3.1 + phase))

            // The failing ones: dark for a fraction of a second, every several seconds.
            if fract(sin(seed * 44.3) * 2217.7) > 0.62 {
                let period = 5.0 + fract(sin(seed * 19.4) * 5514.2) * 7.0
                let cycle = (time + phase).truncatingRemainder(dividingBy: period)
                if cycle < 0.09 || (cycle > 0.17 && cycle < 0.23) { brightness = 0.18 }
            }

            let shape = fract(sin(seed * 88.1) * 4413.7)
            let kind: NeonSign.Kind
            if building.width < 19 && building.height > 26 {
                kind = .blade
            } else if shape > 0.74 && building.height > 22 {
                kind = .rooftop
            } else if shape > 0.46 {
                kind = .storey
            } else {
                kind = .band
            }

            let rect: CGRect
            switch kind {
            case .blade:
                rect = CGRect(
                    x: building.midX - 1.3,
                    y: building.minY + building.height * 0.14,
                    width: 2.6,
                    height: min(building.height * 0.5, 24))
            case .band:
                let width = building.width * 0.64
                rect = CGRect(
                    x: building.midX - width / 2,
                    y: building.minY + building.height * CGFloat(0.16 + pick * 0.3),
                    width: width, height: 2.6)
            case .rooftop:
                let width = building.width * 0.78
                rect = CGRect(
                    x: building.midX - width / 2,
                    y: building.minY - 5.5,
                    width: width, height: 3.4)
            case .storey:
                // Inset from the edges, because a lit floor is windows, not paint.
                rect = CGRect(
                    x: building.minX + 1.4,
                    y: building.minY + building.height * CGFloat(0.3 + pick * 0.45),
                    width: building.width - 2.8, height: 2.2)
            }

            signs.append(NeonSign(
                rect: rect, color: color, brightness: brightness, kind: kind))
        }
        return signs
    }

    /// Tube plus bloom. The bloom is most of the effect — a neon sign is a light source,
    /// and a light source with hard edges and no spill reads as a sticker.
    private func drawNeon(_ context: inout GraphicsContext, signs: [NeonSign]) {
        for sign in signs {
            let tall = sign.kind == .blade
            let bloom = sign.rect.insetBy(
                dx: -sign.rect.width * (tall ? 3.4 : 0.42) - 5,
                dy: -sign.rect.height * (tall ? 0.42 : 3.4) - 5)

            context.fill(
                Path(ellipseIn: bloom),
                with: .radialGradient(
                    Gradient(colors: [
                        sign.color.opacity(0.32 * sign.brightness * litIntensity),
                        .clear,
                    ]),
                    center: CGPoint(x: bloom.midX, y: bloom.midY),
                    startRadius: 0,
                    endRadius: max(bloom.width, bloom.height) / 2))

            context.fill(
                Path(roundedRect: sign.rect, cornerRadius: 1.3),
                with: .color(sign.color.opacity(0.92 * sign.brightness * litIntensity)))

            // A billboard is bolted to something. Two thin legs down to the roof is the
            // whole difference between a sign standing on a building and one floating
            // above it.
            guard sign.kind == .rooftop else { continue }
            var legs = Path()
            for side in [0.25, 0.75] {
                let x = sign.rect.minX + sign.rect.width * CGFloat(side)
                legs.move(to: CGPoint(x: x, y: sign.rect.maxY))
                legs.addLine(to: CGPoint(x: x, y: sign.rect.maxY + 5.5))
            }
            context.stroke(
                legs,
                with: .color(.black.opacity(0.75 * intensity)),
                style: StrokeStyle(lineWidth: 0.7))
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
