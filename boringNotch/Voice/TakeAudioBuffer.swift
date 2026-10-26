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
    private var samples = 0

    /// Converts one tap buffer and appends it. Stops at `CloudConfig.maxTakeSeconds`.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let full = samples >= Self.maxSamples
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
        let room = Self.maxSamples - samples
        let count = min(Int(out.frameLength), room)
        guard count > 0 else { return }
        pcm.append(Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size))
        samples += count
    }

    /// The take as a WAV file, or nil when no audio arrived.
    func wav() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !pcm.isEmpty else { return nil }
        return WAVEncoder.wav(pcm16LE: pcm, sampleRate: Self.sampleRate)
    }

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples) / Double(Self.sampleRate)
    }
}
