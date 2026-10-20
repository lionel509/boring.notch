//
//  MicSpectrumView.swift
//  boringNotch
//
//  The live mic bars in the dictation strip. It reuses the music AudioSpectrum view,
//  but never reads the music tap, so nothing here opens a process tap or starts
//  the decorative music animation.
//

import AppKit
import SwiftUI

struct MicSpectrumView: NSViewRepresentable {
    enum Mode: Equatable {
        /// Recording: the bars follow the mic level, with a slow ripple.
        case live
        /// Transcribing: the bars ripple without the mic.
        case idle
        /// Done: the bars settle to rest.
        case rest
    }

    var mode: Mode

    final class Coordinator {
        var timer: Timer?
        var level: Float = 0
        var last: TimeInterval = ProcessInfo.processInfo.systemUptime
        var mode: Mode = .idle
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.applyLevels([Float](repeating: 0, count: AudioSpectrum.barCount))
        let coordinator = context.coordinator
        coordinator.mode = mode
        // The same cadence as the music spectrum: 30 Hz, or 15 Hz in low power mode.
        let interval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 15 : 1.0 / 30
        let timer = Timer(timeInterval: interval, repeats: true) { [weak spectrum, weak coordinator] timer in
            MainActor.assumeIsolated {
                // The strip is gone: stop ticking instead of firing into nothing.
                guard let spectrum, let coordinator else { timer.invalidate(); return }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = now - coordinator.last
                coordinator.last = now
                let target: Float = coordinator.mode == .live
                    ? (VoiceDictationManager.shared.levelTap?.level ?? 0)
                    : 0
                coordinator.level = MicBars.smooth(coordinator.level, toward: target, dt: dt)
                spectrum.applyLevels(MicBars.levels(
                    level: coordinator.level,
                    time: now,
                    count: AudioSpectrum.barCount,
                    ripple: coordinator.mode != .rest
                ))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        coordinator.timer = timer
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        context.coordinator.mode = mode
    }

    /// Stops the timer with the view, so a closed or replaced strip does not keep ticking.
    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        coordinator.timer = nil
    }
}
