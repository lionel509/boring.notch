import XCTest
@testable import VoiceDictationLogic

/// U2 / v2-2: the take's PCM goes to the STT model as a 44-byte-header WAV.
final class WAVEncoderTests: XCTestCase {
    private func u32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }

    private func u16(_ d: Data, _ at: Int) -> UInt16 {
        UInt16(d[at]) | UInt16(d[at + 1]) << 8
    }

    private func tag(_ d: Data, _ at: Int) -> String {
        String(decoding: d[at..<(at + 4)], as: UTF8.self)
    }

    func testHeaderForThirtyTwoKilobytes() {
        let wav = WAVEncoder.wav(pcm16LE: Data(count: 32_000), sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + 32_000)
        XCTAssertEqual(tag(wav, 0), "RIFF")
        XCTAssertEqual(u32(wav, 4), UInt32(36 + 32_000))
        XCTAssertEqual(tag(wav, 8), "WAVE")
        XCTAssertEqual(tag(wav, 12), "fmt ")
        XCTAssertEqual(u32(wav, 16), 16)
        XCTAssertEqual(u16(wav, 20), 1, "PCM")
        XCTAssertEqual(u16(wav, 22), 1, "mono")
        XCTAssertEqual(u32(wav, 24), 16_000, "sample rate")
        XCTAssertEqual(u32(wav, 28), 32_000, "byte rate")
        XCTAssertEqual(u16(wav, 32), 2, "block align")
        XCTAssertEqual(u16(wav, 34), 16, "bits per sample")
        XCTAssertEqual(tag(wav, 36), "data")
        XCTAssertEqual(u32(wav, 40), 32_000)
    }

    func testEmptyPCMGivesAHeaderOnly() {
        let wav = WAVEncoder.wav(pcm16LE: Data(), sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44)
        XCTAssertEqual(u32(wav, 40), 0)
        XCTAssertEqual(u32(wav, 4), 36)
    }
}
