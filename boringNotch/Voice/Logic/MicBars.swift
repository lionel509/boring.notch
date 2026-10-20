import Foundation

/// Bar heights for the compact mic strip. Pure: the view passes a level and a clock.
enum MicBars {
    static let rippleAmplitude: Float = 0.12
    static let ripplePeriod: TimeInterval = 1.0
    static let rippleStagger: TimeInterval = 0.1
    /// Per 1/60 s: bars rise fast and fall slowly.
    static let riseFactor: Float = 0.85
    static let fallFactor: Float = 0.92

    /// Centre bars are full height; outer bars sit lower in an arc.
    static func bulge(_ i: Int, count: Int) -> Float {
        let d = abs(Float(i) - Float(count - 1) / 2)
        return max(0, 1 - d * d / 16)
    }

    /// A slow wave that travels out from the centre, so an idle strip still moves.
    static func ripple(_ i: Int, count: Int, time: TimeInterval) -> Float {
        let d = abs(Double(i) - Double(count - 1) / 2)
        let phase = 2 * Double.pi * (time - rippleStagger * d) / ripplePeriod
        return rippleAmplitude * Float(0.5 + 0.5 * sin(phase))
    }

    /// Moves `current` toward `target`, frame-rate independent. `dt` is clamped to 0...0.25 s.
    static func smooth(_ current: Float, toward target: Float, dt: TimeInterval) -> Float {
        let step = min(max(dt, 0), 0.25)
        let base = target > current ? riseFactor : fallFactor
        let f = pow(base, Float(step * 60))
        return target + (current - target) * f
    }

    static func levels(level: Float, time: TimeInterval, count: Int, ripple: Bool) -> [Float] {
        let base = min(max(level, 0), 1)
        return (0..<count).map { i in
            let wave = ripple ? Self.ripple(i, count: count, time: time) : 0
            return min(max(base * bulge(i, count: count) + wave, 0), 1)
        }
    }
}
