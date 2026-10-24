import Foundation
import XCTest

/// Source anchor (#17 U3 breaker, Break 3): Cancel during "Learning your voice" closes the sheet, so a voiceprint
/// scored after that must never be written. The app has no XCTest target, so this checks the guard in the source.
final class EnrollmentCancelTests: XCTestCase {
    func testComputeChecksItsSessionAndTheComputingStepBeforeSaving() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("boringNotch/Voice/VoiceEnrollment.swift"), encoding: .utf8)
        guard let computeStart = source.range(of: "private func compute("),
              let save = source.range(of: "Defaults[.dictationVoiceprint] = voiceprint") else {
            return XCTFail("compute() or the voiceprint save moved; re-anchor this test")
        }
        let body = source[computeStart.lowerBound..<save.lowerBound]
        XCTAssertTrue(body.contains("guard token == session"),
                      "compute() saves after Cancel: the session token is not checked")
        XCTAssertTrue(body.contains("guard case .computing = state.step"),
                      "compute() saves without checking the sheet is still computing")
    }
}
