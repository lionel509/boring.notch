import XCTest
@testable import VoiceDictationLogic

/// Breaker round 2 on PR #26 (#17 U2b, head 51099a2). Each test pins an invariant the lease broke.
final class BreakerRound2LeaseTests: XCTestCase {
    /// A superseded take's release must not be lost when a newer take begins first.
    /// Invariant: the model that take A loaded is still released once A ends.
    func testBreakSupersededTakeStillGetsReleased() {
        var lease = SpeakerModelLease()
        lease.begin(); lease.noteEmbedding()   // take A loads the model
        lease.begin()                           // take B starts before A's end arrives
        XCTAssertTrue(lease.endTake(), "A's helper model was forgotten when B began; nothing releases it")
    }

    /// A stale end must not close a take that is still running.
    /// Invariant: A's late release leaves the live take B open.
    func testBreakStaleEndDoesNotCloseLiveTake() {
        var lease = SpeakerModelLease()
        lease.begin(); lease.noteEmbedding()
        lease.begin(); lease.noteEmbedding()
        _ = lease.endTake()                     // A's late release
        XCTAssertTrue(lease.isOpen, "A's late release closed take B while B was still running")
    }
}
