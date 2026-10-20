//
//  MicLevelTap.swift
//  boringNotch
//
//  Feeds the microphone buffers into the pure MicLevelMeter. The engine calls it on
//  the audio thread, so the meter sits behind a lock that the main thread also reads.
//

import AVFoundation
import Foundation
import os

final class MicLevelTap: @unchecked Sendable {
    private struct Counts {
        var configChanges = 0
        var convertFailures = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: MicLevelMeter())
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    /// Counts every buffer. Buffers without float samples still count, so the verdict can tell them apart.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        if let data = buffer.floatChannelData {
            let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
            lock.withLock { $0.ingest(samples, sampleRate: rate, channels: channels) }
        } else {
            let empty = UnsafeBufferPointer<Float>(start: nil, count: 0)
            lock.withLock { $0.ingest(empty, sampleRate: rate, channels: channels) }
        }
    }

    func noteConfigChange() {
        counts.withLock { $0.configChanges += 1 }
    }

    func noteConvertFailure() {
        counts.withLock { $0.convertFailures += 1 }
    }

    var meter: MicLevelMeter {
        lock.withLock { $0 }
    }

    var level: Float {
        meter.level
    }

    func status(elapsed: TimeInterval) -> MicStatus {
        meter.status(elapsed: elapsed)
    }

    func fill(_ report: inout TakeReport) {
        report.record(meter: meter)
        let snapshot = counts.withLock { $0 }
        report.configChanges = snapshot.configChanges
        report.convertFailures = snapshot.convertFailures
    }
}
