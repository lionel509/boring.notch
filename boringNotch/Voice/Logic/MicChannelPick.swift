//
//  MicChannelPick.swift
//  boringNotch
//
//  Which input channel feeds the take. With voice processing on, the input node reports several
//  channels and channel 0 is the processed voice; averaging them all drops the voice about 23 dB.
//

import Foundation

enum MicChannelPick {
    enum Source: Equatable {
        /// One channel: the buffer is already the mono source.
        case passthrough
        /// Use this channel's samples as the mono source.
        case channel(Int)
        /// Several channels with no voice processing: the converter downmixes as before.
        case downmix
    }

    /// The mono source for one tap buffer.
    static func monoSource(channelCount: Int, voiceProcessing: Bool) -> Source {
        if channelCount <= 1 { return .passthrough }
        return voiceProcessing ? .channel(0) : .downmix
    }

    /// The channel with the most energy. Ties go to the lower channel; no channels is channel 0.
    static func loudest(rms: [Float]) -> Int {
        var best = 0
        for (index, value) in rms.enumerated() where value > rms[best] { best = index }
        return best
    }

    /// True when channel 0 sits more than 20 dB below the loudest channel. Silence on channel 0 with a
    /// signal elsewhere counts; all silence keeps channel 0.
    static func needsLoudest(rms: [Float]) -> Bool {
        guard let peak = rms.max(), peak > 0 else { return false }
        let ch0 = rms.first ?? 0
        guard ch0 > 0 else { return true }
        return 20 * log10(ch0 / peak) < -20
    }
}
