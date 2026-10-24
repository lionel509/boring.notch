import XCTest
@testable import VoiceDictationLogic

/// Breaker round 2 on PR #26 (#17 U2b, head 51099a2). Each test pins an invariant the lease broke.
final class BreakerRound2LeaseTests: XCTestCase {
    /// A superseded take's release must not be lost when a newer take begins first.
    /// Invariant: the model that take A loaded is still released once A ends.
    func testBreakSupersededTakeStillGetsReleased() {
        var lease = SpeakerModelLease()
        let a = UUID(), b = UUID()
        lease.begin(a); lease.noteEmbedding(a)   // take A loads the model
        lease.begin(b)                           // take B starts before A's end arrives
        XCTAssertFalse(lease.endTake(a), "A's end is stale while B holds the lease")
        XCTAssertTrue(lease.endTake(b), "A's helper model was forgotten when B began; nothing releases it")
    }

    /// A stale end must not close a take that is still running.
    /// Invariant: A's late release leaves the live take B open.
    func testBreakStaleEndDoesNotCloseLiveTake() {
        var lease = SpeakerModelLease()
        let a = UUID(), b = UUID()
        lease.begin(a); lease.noteEmbedding(a)
        lease.begin(b); lease.noteEmbedding(b)
        _ = lease.endTake(a)                    // A's late release
        XCTAssertTrue(lease.isOpen(b), "A's late release closed take B while B was still running")
    }
}
