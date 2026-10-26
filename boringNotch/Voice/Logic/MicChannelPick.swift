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
}
