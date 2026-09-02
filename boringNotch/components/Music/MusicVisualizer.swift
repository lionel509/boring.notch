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
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
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
            barScales.append(0.35)
            layer?.addSublayer(barLayer)
        }
    }
    
    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
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
            let scale = 0.35 + 0.65 * max(0, min(1, level))
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
            let targetScale = CGFloat.random(in: 0.35 ... 1.0)
            barScales[i] = targetScale
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }
            barLayer.add(animation, forKey: "scaleY")
        }
    }
    
    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[i] = 0.35
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
        let source = SpectrumSource(bandCount: 4)
        var startedFor: String??
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        context.coordinator.source.onBands = { [weak spectrum] levels in
            spectrum?.applyLevels(levels)
        }
        spectrum.update(isPlaying: isPlaying, live: false)
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        let coordinator = context.coordinator
        if isPlaying {
            // Restart the tap when the playing app changes -- a tap is bound to
            // one process and does not follow the user to a different player.
            if coordinator.startedFor != .some(bundleIdentifier) {
                coordinator.source.stop()
                coordinator.source.start(bundleIdentifier: bundleIdentifier)
                coordinator.startedFor = .some(bundleIdentifier)
            }
        } else if coordinator.startedFor != nil {
            coordinator.source.stop()
            coordinator.startedFor = nil
        }
        nsView.update(isPlaying: isPlaying, live: coordinator.source.isLive)
    }

    /// Tearing the tap down with the view is not optional: a process tap holds
    /// an aggregate audio device and an IOProc, and leaking those is worse than
    /// leaking a timer.
    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: Coordinator) {
        coordinator.source.stop()
        nsView.update(isPlaying: false, live: false)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true), bundleIdentifier: nil)
        .frame(width: 16, height: 20)
        .padding()
}
