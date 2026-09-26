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
/// It draws into two `CAShapeLayer`s -- played and unplayed -- straight from the
/// spectrum callback. The first version kept the levels in SwiftUI `@State` and drew in
/// a `Canvas`, which scoped the invalidation to this leaf but still ran a SwiftUI graph
/// update and a layout pass of the *whole* notch 30 times a second: measured with the
/// notch open, this bar alone was ~14% of a core. Setting a layer's path is a Core
/// Animation commit and nothing else.
struct SpectrumTrack: NSViewRepresentable {
    let progress: Double
    let color: Color
    let isPlaying: Bool
    let bundleIdentifier: String?
    /// Height of the flat track this replaces, drawn as-is when no audio is arriving.
    let restingHeight: CGFloat

    func makeNSView(context: Context) -> SpectrumLayerView {
        let view = SpectrumLayerView()
        view.subscribe()
        return view
    }

    func updateNSView(_ view: SpectrumLayerView, context: Context) {
        view.configure(progress: progress, color: NSColor(color), restingHeight: restingHeight)
        view.setPlaying(isPlaying, bundleIdentifier: bundleIdentifier)
    }

    static func dismantleNSView(_ view: SpectrumLayerView, coordinator: ()) {
        view.unsubscribe()
    }
}

final class SpectrumLayerView: NSView {
    /// The floor a live bar sits at. Deliberately thinner than `restingHeight`: with a
    /// 5 pt floor in a 10 pt row the loudest possible band could only be twice the
    /// height of silence, which is why the first version read as a dotted line rather
    /// than as a spectrum.
    private static let liveFloor: CGFloat = 1.5

    /// Frequency, not time: 24 resolved bands interpolated up to something dense
    /// enough to read as a spectrum rather than as an equaliser's chunky sliders.
    /// The interpolation is across neighbouring bands, never across frames — smoothing
    /// in time is exactly what makes a visualiser look asleep.
    private static let barWidth: CGFloat = 2
    private static let barPitch: CGFloat = 3.5

    private let played = CAShapeLayer()
    private let unplayed = CAShapeLayer()
    private var levels: [Float] = []
    private var token: UUID?
    private var progress: Double = 0
    private var restingHeight: CGFloat = 5
    private var playing: Bool?
    private var bundleIdentifier: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        unplayed.fillColor = NSColor.gray.withAlphaComponent(0.3).cgColor
        layer?.addSublayer(unplayed)
        layer?.addSublayer(played)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func subscribe() {
        guard token == nil else { return }
        token = SharedSpectrum.shared.subscribe { [weak self] levels in
            guard let self else { return }
            self.levels = levels
            self.redraw()
        }
    }

    func unsubscribe() {
        if let token { SharedSpectrum.shared.unsubscribe(token) }
        token = nil
        levels = []
    }

    func configure(progress: Double, color: NSColor, restingHeight: CGFloat) {
        self.progress = min(max(progress, 0), 1)
        self.restingHeight = restingHeight
        played.fillColor = color.cgColor
        redraw()
    }

    /// Only on a change: SwiftUI calls `updateNSView` on every progress tick.
    func setPlaying(_ isPlaying: Bool, bundleIdentifier: String?) {
        guard isPlaying != playing || bundleIdentifier != self.bundleIdentifier else { return }
        playing = isPlaying
        self.bundleIdentifier = bundleIdentifier
        SharedSpectrum.shared.update(isPlaying: isPlaying, bundleIdentifier: bundleIdentifier)
        if !isPlaying {
            levels = []
            redraw()
        }
    }

    override func layout() {
        super.layout()
        played.frame = bounds
        unplayed.frame = bounds
        redraw()
    }

    private func redraw() {
        let size = bounds.size
        guard size.width > 0 else { return }
        let playedPath = CGMutablePath()
        let unplayedPath = CGMutablePath()
        let playhead = CGFloat(progress) * size.width
        let midY = size.height / 2

        if levels.isEmpty {
            // No tap, no bars. The audio tap needs macOS 14.4, an entitlement and the
            // user's permission, and until all three land no levels ever arrive --
            // drawing the bar field anyway would put a row of identical stubs on screen,
            // which reads as a broken dotted line rather than as a seek bar. Fall back
            // to the plain rule it replaces.
            let r = restingHeight / 2
            unplayedPath.addRoundedRect(
                in: CGRect(x: 0, y: midY - r, width: size.width, height: restingHeight),
                cornerWidth: r, cornerHeight: r)
            if playhead > 0 {
                playedPath.addRoundedRect(
                    in: CGRect(x: 0, y: midY - r, width: playhead, height: restingHeight),
                    cornerWidth: min(r, playhead / 2), cornerHeight: r)
            }
        } else {
            let count = max(Int(size.width / Self.barPitch), 1)
            let inset = (size.width - CGFloat(count) * Self.barPitch) / 2
            let radius = Self.barWidth / 2
            for index in 0 ..< count {
                let level = CGFloat(Self.expand(sample(at: index, of: count)))
                // Mirrored around the centre line so the bar keeps reading as a rule
                // with progress on it, rather than as a chart sitting on the row's floor.
                let height = Self.liveFloor + level * (size.height - Self.liveFloor)
                let x = inset + CGFloat(index) * Self.barPitch
                let rect = CGRect(x: x, y: midY - height / 2, width: Self.barWidth, height: height)
                let path = x + Self.barWidth / 2 <= playhead ? playedPath : unplayedPath
                path.addRoundedRect(in: rect, cornerWidth: radius,
                                    cornerHeight: min(radius, height / 2))
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        played.path = playedPath
        unplayed.path = unplayedPath
        CATransaction.commit()
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
