import Foundation

/// Wraps 16-bit little-endian PCM in a 44-byte RIFF/WAVE header.
enum WAVEncoder {
    static func wav(pcm16LE: Data, sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(le32(UInt32(36 + pcm16LE.count)))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        out.append(le32(16))
        out.append(le16(1))
        out.append(le16(UInt16(channels)))
        out.append(le32(UInt32(sampleRate)))
        out.append(le32(UInt32(byteRate)))
        out.append(le16(UInt16(blockAlign)))
        out.append(le16(UInt16(bitsPerSample)))
        out.append(contentsOf: Array("data".utf8))
        out.append(le32(UInt32(pcm16LE.count)))
        out.append(pcm16LE)
        return out
    }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xff), UInt8(v >> 8)])
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }
}
