import Foundation
import XCTest
@testable import VoiceDictationLogic

final class TimeoutRaceTests: XCTestCase {
    /// Breaker U3-B3: an operation that ignores cancellation must not hold the caller past the cap.
    func testSlowOperationIsAbandonedAtTheCap() async {
        let start = Date()
        let result: Bool? = await TimeoutRace.run(seconds: 0.5) {
            Thread.sleep(forTimeInterval: 3)
            return true
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.0, "returned after \(elapsed) s")
    }

    func testFastOperationReturnsItsValue() async {
        let result: Int? = await TimeoutRace.run(seconds: 2) { 7 }
        XCTAssertEqual(result, 7)
    }

    func testOperationUnderTheCapReturnsItsValue() async {
        let result: Int? = await TimeoutRace.run(seconds: 2) {
            _ = try? await Task.sleep(for: .milliseconds(100))
            return 42
        }
        XCTAssertEqual(result, 42)
    }
}
