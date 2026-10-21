import XCTest
@testable import VoiceDictationLogic

final class TakeReportTests: XCTestCase {
    /// A take where no buffer arrived must not log the tap's zero defaults as a 0 Hz device.
    func testNoBufferTakeKeepsBufferFieldsUnset() {
        var report = TakeReport()
        report.record(meter: MicLevelMeter())
        XCTAssertTrue(report.line.contains("buf=-1ch/-1Hz"), report.line)
    }

    /// Each field added for #13 has its own key=value token in the line.
    func testNewFieldsAppearInTheLine() {
        var report = TakeReport()
        report.engineStartMs = 42
        report.firstPartialMs = 310
        report.cleanupMs = 706
        report.cleanupApplied = true
        report.cleanupSkip = .none
        report.tone = .email
        report.dictionaryWords = 7
        let tokens = Set(report.line.split(separator: " ").map(String.init))
        XCTAssertTrue(tokens.contains("engine_start_ms=42"), report.line)
        XCTAssertTrue(tokens.contains("first_partial_ms=310"), report.line)
        XCTAssertTrue(tokens.contains("cleanup_ms=706"), report.line)
        XCTAssertTrue(tokens.contains("cleanup=1"), report.line)
        XCTAssertTrue(tokens.contains("skip=none"), report.line)
        XCTAssertTrue(tokens.contains("tone=email"), report.line)
        XCTAssertTrue(tokens.contains("dict=7"), report.line)
    }

    /// A take that never reached the cleanup step logs -1 times, cleanup=0, and the skip reason.
    func testUnsetCleanupFieldsLogTheSkipReason() {
        var report = TakeReport()
        report.cleanupSkip = .disabled
        let tokens = Set(report.line.split(separator: " ").map(String.init))
        XCTAssertTrue(tokens.contains("cleanup_ms=-1"), report.line)
        XCTAssertTrue(tokens.contains("cleanup=0"), report.line)
        XCTAssertTrue(tokens.contains("skip=disabled"), report.line)
        XCTAssertTrue(tokens.contains("tone=neutral"), report.line)
        XCTAssertTrue(tokens.contains("dict=-1"), report.line)
    }
}
