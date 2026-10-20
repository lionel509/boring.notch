import XCTest
@testable import VoiceDictationLogic

final class TakeReportTests: XCTestCase {
    /// A take where no buffer arrived must not log the tap's zero defaults as a 0 Hz device.
    func testNoBufferTakeKeepsBufferFieldsUnset() {
        var report = TakeReport()
        report.record(meter: MicLevelMeter())
        XCTAssertTrue(report.line.contains("buf=-1ch/-1Hz"), report.line)
    }
}
