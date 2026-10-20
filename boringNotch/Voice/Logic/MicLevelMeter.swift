import Foundation

/// What the mic delivered for one take.
enum MicVerdict: String {
    case noBuffers
    case digitalSilence
    case signal
}

/// What the notch shows while the mic is open.
enum MicStatus: Equatable {
    case waiting
    case live
    case quiet
    case noSignal
}

/// Turns mic buffers into a level, a noise floor and a verdict. Pure: no AVFoundation, no clock.
/// Samples are cut into 40 ms chunks, so the numbers do not depend on how the engine sized its buffers.
struct MicLevelMeter {
    static let chunkSeconds: Double = 0.04
    static let rangeDB: Float = 20
    static let silenceDB: Float = -90
    static let startFloorCapDB: Float = -50
    static let lowestFloorDB: Float = -80
    static let voicedMarginDB: Float = 8
    static let noSignalChunks = 25
    static let quietChunks = 125
    static let noBufferSeconds: TimeInterval = 1.5

    private(set) var buffers = 0
    private(set) var chunks = 0
    private(set) var voicedChunks = 0
    private(set) var chunksSinceVoiced = 0
    private(set) var peak: Float = 0
    private(set) var lastDB: Float = -100
    private(set) var maxDB: Float = -100
    private(set) var floorDB: Float? = nil
    private(set) var firstChannels = 0
    private(set) var firstSampleRate: Double = 0
    private var sumSquares: Double = 0
    private var pending = 0
    private var chunkSize = 0

    mutating func ingest(_ samples: [Float], sampleRate: Double, channels: Int) {
        samples.withUnsafeBufferPointer { ingest($0, sampleRate: sampleRate, channels: channels) }
    }

    mutating func ingest(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, channels: Int) {
        buffers += 1
        if buffers == 1 {
            firstChannels = channels
            firstSampleRate = sampleRate
            chunkSize = max(1, Int((sampleRate * Self.chunkSeconds).rounded()))
        }
        for raw in samples {
            let s: Float = raw.isFinite ? raw : 0
            peak = max(peak, abs(s))
            sumSquares += Double(s) * Double(s)
            pending += 1
            if pending == chunkSize { closeChunk() }
        }
    }

    private mutating func closeChunk() {
        let rms = (sumSquares / Double(pending)).squareRoot()
        let dB: Float = rms > 0 ? max(-100, Float(20 * log10(rms))) : -100
        lastDB = dB
        chunks += 1
        maxDB = max(maxDB, dB)
        sumSquares = 0
        pending = 0
        if dB > Self.silenceDB {
            let floor = floorDB.map { min($0, dB) } ?? min(dB, Self.startFloorCapDB)
            floorDB = max(Self.lowestFloorDB, floor)
        }
        if let floor = floorDB, dB >= floor + Self.voicedMarginDB {
            voicedChunks += 1
            chunksSinceVoiced = 0
        } else {
            chunksSinceVoiced += 1
        }
    }

    /// 0...1 above the noise floor, from the last chunk.
    var level: Float {
        guard let floor = floorDB, lastDB > Self.silenceDB else { return 0 }
        return min(1, max(0, (lastDB - floor) / Self.rangeDB))
    }

    var verdict: MicVerdict {
        if buffers == 0 { return .noBuffers }
        if peak < 1e-6 { return .digitalSilence }
        return .signal
    }

    func status(elapsed: TimeInterval) -> MicStatus {
        if buffers == 0 {
            return elapsed >= Self.noBufferSeconds ? .noSignal : .waiting
        }
        if peak < 1e-6 {
            return chunks >= Self.noSignalChunks ? .noSignal : .waiting
        }
        if chunksSinceVoiced >= Self.quietChunks { return .quiet }
        return .live
    }
}
