import XCTest
@testable import VoiceDictationLogic

/// Breaker round 1 against PR #11 (head a9ab598). Each test is an attack on the shared
/// `isUsableRate` guard or on the -1 log marker. Tests that fail here are the findings.
final class MicLevelMeterBreakerTests: XCTestCase {

    /// Break 1: `isUsableRate` accepts any positive rate, so a 0.5 Hz buffer is "usable",
    /// is stored as 0.5, and `Int(0.5)` writes `buf=1ch/0Hz` in the log. That is the exact
    /// 0 Hz ambiguity #9 was meant to remove.
    func testBreaker_subHertzUsableRateMustNotLogAs0Hz() {
        var m = MicLevelMeter()
        m.ingest([0.1, 0.2], sampleRate: 0.5, channels: 1)
        var report = TakeReport()
        report.record(meter: m)
        XCTAssertFalse(report.line.contains("buf=1ch/0Hz"), "got: \(report.line)")
        XCTAssertNotEqual(report.bufferSampleRate, 0, "a usable rate must not log as 0 Hz")
        XCTAssertTrue(report.line.contains("buf=1ch/-1Hz"), "got: \(report.line)")
        XCTAssertEqual(report.bufferSampleRate, -1)
    }

    /// Break 2: the converter in SpeechAnalyzerSession's tap callback computes
    /// `AVAudioFrameCount(Double(frameLength) * (target / format.sampleRate)) + 64`.
    /// AVAudioFrameCount is UInt32, so the conversion traps when the value exceeds UInt32.max.
    /// `isUsableRate` lets rates like 0.01 Hz through, and that overflows for a 4096-frame
    /// tap buffer at a 48 kHz target (4096 * 48000 / 0.01 is about 2e10). The bound is meant to
    /// make the conversion safe, so every rate it accepts should give a capacity that fits.
    func testBreaker_usableRateMustKeepConverterCapacityInUInt32() {
        let frames = 4096.0
        let target = 48_000.0
        var checked = 0
        for rate in [0.01, 0.001, 1e-6, 5e-324, 1_000, 8_000] where MicLevelMeter.isUsableRate(rate) {
            checked += 1
            let capacity = frames * (target / rate) + 64
            XCTAssertLessThanOrEqual(
                capacity, Double(UInt32.max),
                "rate \(rate) is usable but the converter capacity \(capacity) overflows UInt32 and would trap"
            )
        }
        // Guard against a vacuous pass: the real-device rates must reach the assertion.
        XCTAssertGreaterThan(checked, 0)
        XCTAssertTrue(MicLevelMeter.isUsableRate(8_000))
    }
}
