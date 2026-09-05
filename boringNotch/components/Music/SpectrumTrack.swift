//
//  SpectrumTrack.swift
//  boringNotch
//
//  The playback bar, drawn as the spectrum of what is playing through it.
//

import SwiftUI

/// A seek bar whose track is the live spectrum rather than a plain rule.
///
/// The bars run low frequency to high across the width; the playhead is the colour
/// boundary, not a separate knob. That is the whole trick — the row already had to
/// show progress, so the spectrum costs no vertical space, and the closed notch's
/// bars stop being the only place the visualiser is visible.
///
/// It draws in a `Canvas` and keeps the levels in its own `@State`. Both matter: a
/// canvas redraws without rebuilding a view tree, and holding the levels here means
/// the 40 Hz update invalidates this leaf instead of the whole player column with its
/// marquee, its artwork and its lyric scroller.
struct SpectrumTrack: View {
    let progress: Double
    let color: Color
    let isPlaying: Bool
    let bundleIdentifier: String?
    /// Height of the flat track this replaces, drawn as-is when no audio is arriving.
    let restingHeight: CGFloat

    /// The floor a live bar sits at. Deliberately thinner than `restingHeight`: with a
    /// 5 pt floor in a 10 pt row the loudest possible band could only be twice the
    /// height of silence, which is why the first version read as a dotted line rather
    /// than as a spectrum.
    private static let liveFloor: CGFloat = 1.5

    @State private var levels: [Float] = []
    @State private var token: UUID?

    /// Frequency, not time: 24 resolved bands interpolated up to something dense
    /// enough to read as a spectrum rather than as an equaliser's chunky sliders.
    /// The interpolation is across neighbouring bands, never across frames — smoothing
    /// in time is exactly what makes a visualiser look asleep.
    private static let barWidth: CGFloat = 2
    private static let barPitch: CGFloat = 3.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                // No tap, no bars. The audio tap needs macOS 14.4, an entitlement and
                // the user's permission, and until all three land no levels ever
                // arrive -- drawing the bar field anyway would put a row of identical
                // stubs on screen, which reads as a broken dotted line rather than as
                // a seek bar. Fall back to the plain rule it replaces.
                guard !levels.isEmpty else {
                    drawPlainTrack(in: context, size: canvasSize)
                    return
                }

                let count = max(Int(canvasSize.width / Self.barPitch), 1)
                let playhead = min(max(progress, 0), 1) * canvasSize.width
                let midY = canvasSize.height / 2
                let inset = (canvasSize.width - CGFloat(count) * Self.barPitch) / 2

                for index in 0 ..< count {
                    let level = CGFloat(Self.expand(sample(at: index, of: count)))
                    // Mirrored around the centre line so the bar keeps reading as a
                    // rule with progress on it, rather than as a chart sitting on the
                    // row's floor.
                    let height = Self.liveFloor
                        + level * (canvasSize.height - Self.liveFloor)
                    let x = inset + CGFloat(index) * Self.barPitch
                    let rect = CGRect(
                        x: x,
                        y: midY - height / 2,
                        width: Self.barWidth,
                        height: height)

                    let played = x + Self.barWidth / 2 <= playhead
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                        with: .color(played ? color : Color.gray.opacity(0.3)))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .onAppear {
            guard token == nil else { return }
            token = SharedSpectrum.shared.subscribe { levels in
                self.levels = levels
            }
            SharedSpectrum.shared.update(isPlaying: isPlaying, bundleIdentifier: bundleIdentifier)
        }
        .onDisappear {
            if let token {
                SharedSpectrum.shared.unsubscribe(token)
                self.token = nil
            }
            levels = []
        }
        .onChange(of: isPlaying) { _, playing in
            SharedSpectrum.shared.update(isPlaying: playing, bundleIdentifier: bundleIdentifier)
            if !playing { levels = [] }
        }
        .onChange(of: bundleIdentifier) { _, identifier in
            SharedSpectrum.shared.update(isPlaying: isPlaying, bundleIdentifier: identifier)
        }
    }

    /// The bar this view replaces: a grey rule with the played part filled in.
    private func drawPlainTrack(in context: GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let played = min(max(progress, 0), 1) * size.width

        let track = CGRect(
            x: 0, y: midY - restingHeight / 2,
            width: size.width, height: restingHeight)
        context.fill(
            Path(roundedRect: track, cornerRadius: restingHeight / 2),
            with: .color(.gray.opacity(0.3)))

        guard played > 0 else { return }
        let fill = CGRect(
            x: 0, y: midY - restingHeight / 2,
            width: played, height: restingHeight)
        context.fill(
            Path(roundedRect: fill, cornerRadius: restingHeight / 2),
            with: .color(color))
    }

    /// Stretch the working range across the full height.
    ///
    /// The engine maps a 60 dB window onto 0...1 honestly, and ordinary music lives in
    /// the top half of it: every band sat between 0.4 and 0.7, so the bars differed by
    /// a couple of points and the whole row looked flat. This is a contrast curve, not
    /// a gain -- quiet still reads as quiet, but the part of the range music actually
    /// occupies is what the height now spends itself on.
    private static func expand(_ level: Float) -> Float {
        let floor: Float = 0.22
        let ceiling: Float = 0.88
        let normalised = (level - floor) / (ceiling - floor)
        return min(max(normalised, 0), 1)
    }

    /// Linear interpolation between the two bands either side of this bar. Only the
    /// low bands of a 2048-point FFT are genuinely crowded; everywhere else this is
    /// drawing between two real measurements rather than inventing detail.
    private func sample(at index: Int, of count: Int) -> Float {
        guard !levels.isEmpty else { return 0 }
        guard levels.count > 1, count > 1 else { return levels[0] }

        let position = Float(index) / Float(count - 1) * Float(levels.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, levels.count - 1)
        let fraction = position - Float(lower)
        return levels[lower] + (levels[upper] - levels[lower]) * fraction
    }
}
