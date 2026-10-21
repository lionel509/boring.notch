import XCTest
@testable import VoiceDictationLogic

/// Breaker round 2 against PR #11 (head 11ac6a9). Only the test that fails on this head is kept.
final class MicLevelMeterBreakerR2Tests: XCTestCase {

    /// The 1 kHz floor does not bound the converter's frame capacity for every frame count.
    /// At rate 1000 with a 48 kHz target the ratio is 48, so about 89.5M frames overflow UInt32,
    /// and AVAudioFrameCount(Double) traps. The formula is copied from the tap callback in
    /// SpeechAnalyzerSession (app target, not importable here). Theoretical: CoreAudio taps
    /// deliver a few thousand frames, not 89M.
    func testCapacity_lowestUsableRateWithHugeFrameCountStillOverflows() {
        let rate = 1_000.0
        let target = 48_000.0
        let frames = 90_000_000.0
        let capacity = frames * (target / rate) + 64
        XCTAssertLessThanOrEqual(capacity, Double(UInt32.max),
            "usable rate \(rate) gives capacity \(capacity) for \(frames) frames, which overflows UInt32 and traps")
    }
}
