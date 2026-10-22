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

    /// The timed-out operation is cancelled, so a cloud request stops once the fallback has started.
    func testTimedOutOperationIsCancelled() async {
        let box = CancelBox()
        let result: Int? = await TimeoutRace.run(seconds: 0.05) {
            _ = try? await Task.sleep(for: .seconds(2))
            box.record(Task.isCancelled)
            return 1
        }
        XCTAssertNil(result)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(box.value, true, "the timed-out operation was not cancelled")
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

/// Holds the cancellation flag the operation saw, written from the operation's task.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    func record(_ cancelled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        stored = cancelled
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
