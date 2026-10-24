//
//  TakeAudioBuffer.swift
//  boringNotch
//

import AVFoundation
import Foundation

/// Keeps one take's microphone audio as 16 kHz mono PCM, so the cloud transcript can be sent as a WAV.
/// `ingest` runs on the audio thread; `wav` runs on the main actor after the key is released.
final class TakeAudioBuffer: @unchecked Sendable {
    private static let sampleRate = 16_000
    private static let maxSamples = CloudConfig.maxTakeSeconds * sampleRate

    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)
    /// Only the audio thread touches the converter and its input format.
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var pcm = Data()
    private var sampleCount = 0

    /// Converts one tap buffer and appends it. Stops at `CloudConfig.maxTakeSeconds`.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let full = sampleCount >= Self.maxSamples
        lock.unlock()
        guard !full, let target else { return }

        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInput = buffer.format
        }
        guard let converter else { return }
        let ratio = Double(Self.sampleRate) / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        lock.lock()
        defer { lock.unlock() }
        let room = Self.maxSamples - sampleCount
        let count = min(Int(out.frameLength), room)
        guard count > 0 else { return }
        pcm.append(Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size))
        sampleCount += count
    }

    /// The take as a WAV file, or nil when no audio arrived.
    func wav() -> Data? {
        wav(silencing: [])
    }

    /// The take as a WAV file with the samples inside `ranges` (seconds) zeroed, or nil when no audio arrived.
    func wav(silencing ranges: [ClosedRange<Double>]) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !pcm.isEmpty else { return nil }
        let kept = SpeakerGate.silence(pcm16LE: pcm, ranges: ranges, sampleRate: Self.sampleRate)
        return WAVEncoder.wav(pcm16LE: kept, sampleRate: Self.sampleRate)
    }

    /// The span [from, to] seconds as Float samples in [-1, 1] (Int16 / 32768). [] when the span is empty,
    /// inverted, or starts past the end of the take. Never traps on any input.
    func samples(from: Double, to: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let total = pcm.count / MemoryLayout<Int16>.size
        guard from.isFinite, to.isFinite, to > from else { return [] }
        let lower = Int(min(max(from * Double(Self.sampleRate), 0), Double(total)))
        let upper = Int(min(max(to * Double(Self.sampleRate), 0), Double(total)))
        guard upper > lower else { return [] }
        return pcm.withUnsafeBytes { raw -> [Float] in
            (lower..<upper).map { index in
                let value = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                return Float(Int16(littleEndian: value)) / 32_768
            }
        }
    }

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(sampleCount) / Double(Self.sampleRate)
    }
}
