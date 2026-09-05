//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

class AudioSpectrum: NSView {
    /// Seven, in the ~20 pt the closed notch allows. Four was too few to show anything
    /// but "loud"; nine at 1.2 pt with a 0.9 pt gap closed up into a picket fence, where
    /// the gaps were narrower than the bars and the whole thing read as one block. The
    /// gap has to stay comparable to the bar for a bar to be legible as a bar.
    static let barCount = 7
    private static let barWidth: CGFloat = 1.7
    private static let spacing: CGFloat = 1.3

    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth = Self.barWidth
        let barCount = Self.barCount
        let spacing = Self.spacing
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            barScales.append(0.18)
            layer?.addSublayer(barLayer)
        }
    }
    
    private func startAnimating() {
        guard animationTimer == nil else { return }
        // The decorative fallback, used when no tap is running. It used to step every
        // 0.3 s and autoreverse, so each bar spent 0.6 s on one excursion and the strip
        // swayed rather than moved. Nine bars at 8 Hz reads as a signal instead.
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
    }
    
    private func stopAnimating(reset: Bool = true) {
        animationTimer?.invalidate()
        animationTimer = nil
        if reset { resetBars() }
    }
    
    /// Drive the bars from real FFT output. No CABasicAnimation here: the
    /// engine already smooths with an attack/decay envelope, and adding an
    /// animation per bar 30 times a second is exactly the kind of runloop churn
    /// this app has been bitten by before.
    func applyLevels(_ levels: [Float]) {
        guard !levels.isEmpty else { return }
        stopAnimating(reset: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, barLayer) in barLayers.enumerated() {
            let level = i < levels.count ? CGFloat(levels[i]) : 0
            let scale = 0.18 + 0.82 * max(0, min(1, level))
            barScales[i] = scale
            barLayer.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }

    /// `live` means a tap is feeding `applyLevels`; the decorative random
    /// animation is only started when it is not.
    func update(isPlaying playing: Bool, live: Bool) {
        isPlaying = playing
        if live {
            stopAnimating(reset: false)
        } else if playing {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func updateBars() {
        for (i, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[i]
            let targetScale = CGFloat.random(in: 0.18 ... 1.0)
            barScales[i] = targetScale
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.12
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            }
            barLayer.add(animation, forKey: "scaleY")
        }
    }
    
    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.18, 1)
            barScales[i] = 0.18
        }
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    /// Bundle id of the app currently playing. The process tap needs it to find
    /// its target; without one the view falls back to the decorative animation.
    var bundleIdentifier: String?

    final class Coordinator {
        var token: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        let coordinator = context.coordinator
        // The tap is shared with the playback track in the open notch, so this view
        // subscribes rather than opening its own. The engine resolves more bands than
        // there are bars here; folding them down by peak keeps a transient that lands
        // in one band from being averaged away by its quiet neighbours.
        coordinator.token = SharedSpectrum.shared.subscribe { [weak spectrum] levels in
            spectrum?.applyLevels(SharedSpectrum.fold(levels, into: AudioSpectrum.barCount))
        }
        spectrum.update(isPlaying: isPlaying, live: false)
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        SharedSpectrum.shared.update(isPlaying: isPlaying, bundleIdentifier: bundleIdentifier)
        nsView.update(isPlaying: isPlaying, live: SharedSpectrum.shared.isLive)
    }

    /// Dropping the subscription with the view is not optional: the shared tap holds
    /// an aggregate audio device and an IOProc for as long as anyone is listening,
    /// and leaking those is worse than leaking a timer.
    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: Coordinator) {
        if let token = coordinator.token {
            SharedSpectrum.shared.unsubscribe(token)
            coordinator.token = nil
        }
        nsView.update(isPlaying: false, live: false)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true), bundleIdentifier: nil)
        .frame(width: 19, height: 20)
        .padding()
}
