import XCTest
@testable import VoiceDictationLogic

final class TakeReportTests: XCTestCase {
    /// A take where no buffer arrived must not log the tap's zero defaults as a 0 Hz device.
    func testNoBufferTakeKeepsBufferFieldsUnset() {
        var report = TakeReport()
        report.record(meter: MicLevelMeter())
        XCTAssertTrue(report.line.contains("buf=-1ch/-1Hz"), report.line)
    }

    /// U5 / v4-3: every rewrite field is in the line, unset as -1 or none, so the demo can read it.
    func testRewriteKeysAreInTheLineWhenUnset() {
        var report = TakeReport()
        report.record(meter: MicLevelMeter())
        let words = report.line.components(separatedBy: " ")
        let keys = [
            "engine_start_ms=-1", "first_partial_ms=-1", "stt_ms=-1", "stt=none", "stt_s=-1.00",
            "stt_uusd=-1", "first_cleanup_ms=-1", "llm_ttft_ms=-1", "llm_ms=-1", "llm_in=-1",
            "llm_out=-1", "swaps=-1", "max_swap_ms=-1", "mech=none", "rewrite=none",
            "cleanup=none", "skip=none", "tone=neutral", "dict=-1", "cloud=0",
        ]
        for key in keys {
            XCTAssertTrue(words.contains(key), "\(key) missing from \(report.line)")
        }
    }

    func testRewriteKeysCarryWhatTheTakeSet() {
        var report = TakeReport()
        report.record(meter: MicLevelMeter())
        report.sttSource = .assemblyai
        report.mechanism = .ax
        report.swaps = 4
        report.sttMs = 452
        report.cloud = true
        let words = report.line.components(separatedBy: " ")
        for key in ["stt=assemblyai", "mech=ax", "swaps=4", "stt_ms=452", "cloud=1", "rewrite=none"] {
            XCTAssertTrue(words.contains(key), "\(key) missing from \(report.line)")
        }
    }
}
