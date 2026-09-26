//
//  RecordPlayerView.swift
//  boringNotch
//

import SwiftUI

/// The artwork as a record player: the cover is the label of a record that spins while
/// music plays, under a needle that walks inward as the track goes. Pausing lifts the arm
/// and the record stops where it is; changing track swaps the record.
///
/// Three layouts of the same mechanism, kept together so they can be compared live:
/// a bare record and arm, a Technics-style deck, and a sleeve the record slides out of.
struct RecordPlayerView: View {
    enum Layout { case record, deck, sleeve }

    let layout: Layout
    let art: NSImage
    let title: String
    let artist: String
    var accent: Color = .white
    let isPlaying: Bool
    /// Changes when the track does. Drives the record swap.
    let trackKey: String
    let skippedBackward: Bool
    /// 0...1 through the track at a given moment, so the needle can walk inward.
    var progress: (Date) -> Double = { _ in 0 }

    @State private var spinStart: Date?
    @State private var armDown: Bool
    /// Sleeve layout only: the record is out of its sleeve.
    @State private var recordOut: Bool
    @State private var changingRecord = false

    init(layout: Layout, art: NSImage, title: String, artist: String, accent: Color = .white,
         isPlaying: Bool, trackKey: String, skippedBackward: Bool,
         progress: @escaping (Date) -> Double = { _ in 0 }) {
        self.layout = layout
        self.art = art
        self.title = title
        self.artist = artist
        self.accent = accent
        self.isPlaying = isPlaying
        self.trackKey = trackKey
        self.skippedBackward = skippedBackward
        self.progress = progress
        // Start in the right pose rather than animating into it every time the notch opens.
        _armDown = State(initialValue: isPlaying)
        _recordOut = State(initialValue: isPlaying)
        _spinStart = State(initialValue: isPlaying ? Date() : nil)
    }

    // MARK: - Geometry

    /// Everything in units of the view's height, so the layout scales as one piece.
    private struct Geometry {
        var aspect: CGFloat
        var disc: CGPoint            // record centre while playing
        var discDiameter: CGFloat
        var pivot: CGPoint
        var armLength: CGFloat
        var counterweight: CGFloat   // how far the arm reaches back past the pivot
        var sCurve: Bool
    }

    private var geometry: Geometry {
        switch layout {
        case .record:
            Geometry(aspect: 1, disc: CGPoint(x: 0.43, y: 0.41), discDiameter: 0.80,
                     pivot: CGPoint(x: 0.87, y: 0.11), armLength: 0.56,
                     counterweight: 0.1, sCurve: false)
        case .deck:
            Geometry(aspect: 1, disc: CGPoint(x: 0.41, y: 0.43), discDiameter: 0.70,
                     pivot: CGPoint(x: 0.85, y: 0.15), armLength: 0.56,
                     counterweight: 0.11, sCurve: true)
        case .sleeve:
            Geometry(aspect: 1.3, disc: CGPoint(x: 0.82, y: 0.5), discDiameter: 0.9,
                     pivot: CGPoint(x: 1.2, y: 0.08), armLength: 0.5,
                     counterweight: 0.08, sCurve: false)
        }
    }

    private static let labelFraction: CGFloat = 0.52

    /// The arm angle (clockwise from hanging straight down) that puts the stylus `radius`
    /// from the record's centre. The stylus sits at pivot + L(-sin t, cos t), so
    /// |pivot - centre + L(-sin t, cos t)| = r reduces to A cos(t + phi) = k.
    private func armAngle(stylusRadius r: CGFloat) -> Double {
        let g = geometry
        let vx = g.pivot.x - g.disc.x, vy = g.pivot.y - g.disc.y, l = g.armLength
        let k = (r * r - vx * vx - vy * vy - l * l) / (2 * l)
        let a = (vx * vx + vy * vy).squareRoot()
        let phi = atan2(vx, vy)
        return Double((acos(min(max(k / a, -1), 1)) - phi) * 180 / .pi)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let g = geometry
            let h = min(geo.size.height, geo.size.width / g.aspect)
            ZStack(alignment: .topLeading) {
                switch layout {
                case .record: recordLayout(h: h)
                case .deck: deckLayout(h: h)
                case .sleeve: sleeveLayout(h: h)
                }
            }
            .frame(width: h * g.aspect, height: h)
            .clipped()
        }
        .aspectRatio(geometry.aspect, contentMode: .fit)
        .animation(.smooth(duration: 0.55), value: trackKey)
        .onChange(of: isPlaying) { _, playing in setPlaying(playing) }
        .onChange(of: trackKey) {
            // Arm up while the records trade places, back down once the new one is on.
            changingRecord = true
            withAnimation(.easeOut(duration: 0.25)) { armDown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                changingRecord = false
                withAnimation(.spring(duration: 0.5, bounce: 0.15)) { armDown = isPlaying }
            }
        }
    }

    private func setPlaying(_ playing: Bool) {
        spinStart = playing ? (spinStart ?? Date()) : nil
        guard !changingRecord else { return }
        // Order matters in the sleeve: the record comes out before the needle drops, and
        // the needle lifts before the record goes back in.
        let slide = Animation.spring(duration: 0.6, bounce: 0.1)
        let arm = Animation.spring(duration: 0.5, bounce: 0.15)
        if playing {
            withAnimation(slide) { recordOut = true }
            withAnimation(layout == .sleeve ? arm.delay(0.35) : arm) { armDown = true }
        } else {
            withAnimation(arm) { armDown = false }
            withAnimation(slide.delay(0.25)) { recordOut = false }
        }
    }

    /// The part that changes with the track, sliding off one way and on from the other.
    private func swappable<V: View>(_ content: V) -> some View {
        content
            .id(trackKey)
            .transition(.asymmetric(
                insertion: .move(edge: skippedBackward ? .leading : .trailing),
                removal: .move(edge: skippedBackward ? .trailing : .leading)))
    }

    // MARK: - Layouts

    private func recordLayout(h: CGFloat) -> some View {
        let g = geometry
        return ZStack(alignment: .topLeading) {
            swappable(record(diameter: g.discDiameter * h))
                .position(x: g.disc.x * h, y: g.disc.y * h)
            armBase(h: h, size: 0.13)
                .position(x: g.pivot.x * h, y: g.pivot.y * h)
            tonearm(h: h)
            identity(h: h)
                .frame(width: h * 0.94, alignment: .leading)
                .position(x: h * 0.5, y: h * 0.9)
        }
    }

    private func deckLayout(h: CGFloat) -> some View {
        let g = geometry
        let platter = (g.discDiameter + 0.07) * h
        return ZStack(alignment: .topLeading) {
            plinth(h: h)
            Canvas { ctx, size in
                // Platter with the strobe dots round its rim, the thing that makes a deck
                // read as a Technics at a glance.
                let r = size.width / 2
                ctx.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)),
                         with: .linearGradient(
                            Gradient(colors: [Color(white: 0.42), Color(white: 0.2)]),
                            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                let dot = max(size.width * 0.012, 0.8)
                for i in 0..<72 {
                    let a = Double(i) / 72 * 2 * .pi
                    let p = CGPoint(x: r + CGFloat(cos(a)) * (r - dot * 1.6),
                                    y: r + CGFloat(sin(a)) * (r - dot * 1.6))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - dot / 2, y: p.y - dot / 2,
                                                    width: dot, height: dot)),
                             with: .color(.white.opacity(0.35)))
                }
            }
            .frame(width: platter, height: platter)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
            .position(x: g.disc.x * h, y: g.disc.y * h)
            swappable(record(diameter: g.discDiameter * h))
                .position(x: g.disc.x * h, y: g.disc.y * h)
            armBase(h: h, size: 0.17)
                .position(x: g.pivot.x * h, y: g.pivot.y * h)
            tonearm(h: h)
            identity(h: h)
                .frame(width: h * 0.62, alignment: .leading)
                .position(x: h * 0.37, y: h * 0.89)
            speedButtons(h: h)
                .position(x: h * 0.81, y: h * 0.9)
        }
    }

    private func sleeveLayout(h: CGFloat) -> some View {
        let g = geometry
        // Tucked in, the record sits behind the middle of the sleeve.
        let x = recordOut ? g.disc.x : 0.5
        return ZStack(alignment: .topLeading) {
            swappable(
                ZStack(alignment: .topLeading) {
                    record(diameter: g.discDiameter * h)
                        .position(x: x * h, y: g.disc.y * h)
                    sleeve(h: h)
                        .frame(width: h, height: h)
                        .position(x: h / 2, y: h / 2)
                }
                .frame(width: h * g.aspect, height: h))
            tonearm(h: h)
            armBase(h: h, size: 0.1)
                .position(x: g.pivot.x * h, y: g.pivot.y * h)
        }
    }

    // MARK: - Pieces

    private func identity(h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: max(h * 0.085, 9), weight: .semibold))
                .foregroundStyle(.white)
            if !artist.isEmpty {
                Text(artist)
                    .font(.system(size: max(h * 0.07, 8), weight: .medium))
                    .foregroundStyle(accent)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func record(diameter d: CGFloat) -> some View {
        let label = d * Self.labelFraction
        return ZStack {
            // Grooves look the same at any angle, so only the label turns, and it turns in
            // Core Animation: nothing here redraws while the record spins.
            Canvas { ctx, size in
                let r = size.width / 2
                let c = CGPoint(x: r, y: r)
                func ring(_ radius: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                           width: radius * 2, height: radius * 2))
                }
                ctx.fill(ring(r), with: .radialGradient(
                    Gradient(colors: [Color(white: 0.13), Color(white: 0.06), Color(white: 0.03)]),
                    center: c, startRadius: 0, endRadius: r))
                // Fine grooves, with a blank band where one track would end and the next begin.
                let outer = r * 0.96, inner = label / 2 + r * 0.04
                var radius = outer
                var i = 0
                while radius > inner {
                    if abs(radius - (inner + (outer - inner) * 0.62)) > r * 0.018 {
                        ctx.stroke(ring(radius),
                                   with: .color(.white.opacity(i.isMultiple(of: 3) ? 0.075 : 0.035)),
                                   lineWidth: 0.5)
                    }
                    radius -= r * 0.022
                    i += 1
                }
                ctx.stroke(ring(r - 0.5), with: .color(.white.opacity(0.14)), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.7), radius: 5, y: 2)

            SpinningLabel(art: art, spinning: spinStart != nil)
                .frame(width: label, height: label)
            Circle()
                .fill(Color(white: 0.02))
                .frame(width: d * 0.035, height: d * 0.035)
            Circle()
                .strokeBorder(.black.opacity(0.55), lineWidth: max(d * 0.012, 1))
                .frame(width: label, height: label)

            // Stationary sheen: light on a real record does not turn with it.
            Circle()
                .fill(AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .white.opacity(0.16), location: 0.10),
                        .init(color: .clear, location: 0.22),
                        .init(color: .clear, location: 0.50),
                        .init(color: .white.opacity(0.12), location: 0.60),
                        .init(color: .clear, location: 0.72),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .center, angle: .degrees(-20)))
                .mask(Circle().strokeBorder(lineWidth: (d - label) / 2))
                .allowsHitTesting(false)
        }
        .frame(width: d, height: d)
    }

    /// Dark anodised aluminium, brushed, with a lit top edge.
    private func plinth(h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: h * 0.07, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    var i = 0
                    while y < size.height {
                        let o = [0.035, 0.015, 0.05, 0.02, 0.03][i % 5]
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                                 with: .color(.white.opacity(o)))
                        y += 1.5
                        i += 1
                    }
                }
                .clipShape(shape))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .frame(width: h, height: h)
            .position(x: h / 2, y: h / 2)
    }

    private func speedButtons(h: CGFloat) -> some View {
        HStack(spacing: h * 0.03) {
            ForEach(["33", "45"], id: \.self) { speed in
                Text(speed)
                    .font(.system(size: max(h * 0.05, 6), weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: h * 0.1, height: h * 0.065)
                    .background(RoundedRectangle(cornerRadius: h * 0.012).fill(Color(white: 0.1)))
                    .overlay(alignment: .top) {
                        // The lamp over 33 is lit while the platter turns.
                        if speed == "33" {
                            Circle()
                                .fill(isPlaying ? Color.orange : Color(white: 0.25))
                                .frame(width: h * 0.018, height: h * 0.018)
                                .shadow(color: .orange.opacity(isPlaying ? 0.9 : 0), radius: 2)
                                .offset(y: -h * 0.03)
                        }
                    }
            }
        }
    }

    private func sleeve(h: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: art)
                .resizable()
                .scaledToFill()
                .frame(width: h, height: h)
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0.45),
                    .init(color: .black.opacity(0.8), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
            identity(h: h)
                .padding(.horizontal, h * 0.05)
                .padding(.bottom, h * 0.04)
        }
        .clipShape(RoundedRectangle(cornerRadius: h * 0.05, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: h * 0.05, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 5, x: 3)
    }

    private func armBase(h: CGFloat, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.36), Color(white: 0.14)],
                                     center: .center, startRadius: 0, endRadius: h * size * 0.55))
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            Circle()
                .fill(Color(white: 0.07))
                .frame(width: h * size * 0.45, height: h * size * 0.45)
        }
        .frame(width: h * size, height: h * size)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    /// Walks from the outer groove to the edge of the label as the track plays; parked
    /// off the record otherwise. Updated once a second: a whole track moves it ~15 degrees.
    private func tonearm(h: CGFloat) -> some View {
        let g = geometry
        let r = g.discDiameter / 2
        let outer = armAngle(stylusRadius: r * 0.9)
        let inner = armAngle(stylusRadius: r * (Self.labelFraction + 0.08))
        // Parked clear of the rim -- and on the deck, clear of the platter too. The sleeve
        // arm just hangs: its record has gone back into the sleeve, and swinging outward
        // would take it off the edge of the frame.
        let rest = switch layout {
        case .record: armAngle(stylusRadius: r + 0.12)
        case .deck: armAngle(stylusRadius: r + 0.13)
        case .sleeve: 0.0
        }
        let behind = g.counterweight * h
        let height = behind + g.armLength * h + h * 0.03
        let width = h * 0.16
        return TimelineView(Ticks(every: 1, paused: spinStart == nil)) { tl in
            let p = min(max(progress(tl.date), 0), 1)
            armDrawing(h: h, width: width, height: height, behind: behind)
                .rotationEffect(.degrees(armDown ? outer + (inner - outer) * p : rest),
                                anchor: UnitPoint(x: 0.5, y: behind / height))
                .position(x: g.pivot.x * h, y: g.pivot.y * h - behind + height / 2)
        }
    }

    /// Hanging straight down from the pivot at (width/2, behind): counterweight, tube
    /// (S-bent on the deck), headshell. The stylus lands `armLength` below the pivot, the
    /// length the angles above are solved for.
    private func armDrawing(h: CGFloat, width: CGFloat, height: CGFloat, behind: CGFloat) -> some View {
        let g = geometry
        let sCurve = g.sCurve
        return Canvas { ctx, _ in
            let cx = width / 2
            let tip = CGPoint(x: cx, y: behind + g.armLength * h)
            let head = h * 0.1
            let neck = CGPoint(x: cx, y: tip.y - head)

            var shadowed = ctx
            shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 2, x: -1.5, y: 2.5))

            // Counterweight.
            let weight = CGRect(x: cx - h * 0.04, y: behind * 0.05, width: h * 0.08, height: behind * 0.75)
            shadowed.fill(Path(roundedRect: weight, cornerRadius: h * 0.015),
                          with: .linearGradient(
                            Gradient(colors: [Color(white: 0.6), Color(white: 0.22)]),
                            startPoint: CGPoint(x: weight.minX, y: 0),
                            endPoint: CGPoint(x: weight.maxX, y: 0)))

            // Tube.
            var tube = Path()
            tube.move(to: CGPoint(x: cx, y: behind * 0.5))
            if sCurve {
                let span = neck.y - behind
                tube.addLine(to: CGPoint(x: cx, y: behind))
                tube.addCurve(to: neck,
                              control1: CGPoint(x: cx + h * 0.09, y: behind + span * 0.45),
                              control2: CGPoint(x: cx - h * 0.09, y: behind + span * 0.7))
            } else {
                tube.addLine(to: neck)
            }
            let tubeWidth = max(h * 0.03, 2.5)
            shadowed.stroke(tube, with: .color(Color(white: 0.45)),
                            style: StrokeStyle(lineWidth: tubeWidth + 1, lineCap: .round))
            ctx.stroke(tube, with: .color(Color(white: 0.88)),
                       style: StrokeStyle(lineWidth: tubeWidth - 0.5, lineCap: .round))

            // Headshell, kinked toward the spindle the way real ones are, and its cartridge.
            var shell = ctx
            shell.translateBy(x: neck.x, y: neck.y)
            shell.rotate(by: .degrees(20))
            shell.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5, x: -1, y: 2))
            let body = CGRect(x: -h * 0.035, y: -h * 0.01, width: h * 0.07, height: head)
            shell.fill(Path(roundedRect: body, cornerRadius: h * 0.012),
                       with: .color(Color(white: 0.82)))
            shell.fill(Path(roundedRect: CGRect(x: -h * 0.025, y: head * 0.45,
                                                width: h * 0.05, height: head * 0.45),
                            cornerRadius: h * 0.006),
                       with: .color(Color(white: 0.1)))
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

/// The record's label, spun by a repeating Core Animation rotation.
///
/// The first version drove `rotationEffect` from a 30 fps `TimelineView`, which is a
/// SwiftUI update and a layout pass of the whole notch per frame. This is one animation
/// handed to the render server; pausing freezes the layer's clock where it is, so the
/// record still stops mid-turn rather than snapping back.
private struct SpinningLabel: NSViewRepresentable {
    let art: NSImage
    let spinning: Bool

    func makeNSView(context: Context) -> SpinningLabelView { SpinningLabelView() }

    func updateNSView(_ view: SpinningLabelView, context: Context) {
        view.setArt(art)
        view.setSpinning(spinning)
    }
}

private final class SpinningLabelView: NSView {
    /// 33 1/3 rpm.
    private static let secondsPerTurn = 1.8

    private let label = CALayer()
    private weak var art: NSImage?
    private var spinning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.contentsGravity = .resizeAspectFill
        label.masksToBounds = true
        layer?.addSublayer(label)

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi          // negative is clockwise in an unflipped layer
        turn.duration = Self.secondsPerTurn
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        label.add(turn, forKey: "spin")
        freeze()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.frame = bounds
        label.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }

    func setArt(_ image: NSImage) {
        guard image !== art else { return }
        art = image
        label.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func setSpinning(_ on: Bool) {
        guard on != spinning else { return }
        spinning = on
        if on {
            let pausedAt = label.timeOffset
            label.speed = 1
            label.timeOffset = 0
            label.beginTime = 0
            label.beginTime = label.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        } else {
            freeze()
        }
    }

    private func freeze() {
        let now = label.convertTime(CACurrentMediaTime(), from: nil)
        label.speed = 0
        label.timeOffset = now
    }
}

/// A timeline that fires every `every` seconds off a timer, or once when paused.
///
/// `.animation(minimumInterval:)` looks like the same thing and is not: it subscribes to
/// the display link at the full refresh rate and skips the frames it does not want, so a
/// once-a-second clock still woke the main thread 120 times a second, and every wakeup
/// flushed a transaction and re-ran layout for the whole notch.
struct Ticks: TimelineSchedule {
    let every: TimeInterval
    var paused = false

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = start
        return AnyIterator {
            guard let date = next else { return nil }
            next = paused ? nil : date.addingTimeInterval(every)
            return date
        }
    }
}
