import XCTest
@testable import VoiceDictationLogic

/// The take's speaker bookkeeping (#17 U2b fix round): the lease that closes at the take's end, the transcript that
/// keeps every final in place while its embedding is pending, and the bounded wait for the tail's embedding.
final class SpeakerTakeTests: XCTestCase {
    func testLeaseIsClosedUntilTheTakeBegins() {
        var lease = SpeakerModelLease()
        let take = UUID()
        XCTAssertFalse(lease.isOpen(take))
        lease.begin(take)
        XCTAssertTrue(lease.isOpen(take))
    }

    func testLeaseClosesWhenTheTakeEndsAndReopensOnTheNextBegin() {
        var lease = SpeakerModelLease()
        let first = UUID(), second = UUID()
        lease.begin(first)
        lease.noteEmbedding(first)
        XCTAssertTrue(lease.endTake(first), "a take that embedded must release")
        XCTAssertFalse(lease.isOpen(first), "a window after the take's end must find the lease closed")
        lease.begin(second)
        XCTAssertTrue(lease.isOpen(second))
        XCTAssertFalse(lease.endTake(second), "a take that never embedded releases nothing")
    }

    func testSupersededTakeReleasesOnceAfterTheLiveTakeEnds() {
        var lease = SpeakerModelLease()
        let first = UUID(), second = UUID()
        lease.begin(first)
        lease.noteEmbedding(first)
        lease.begin(second)
        XCTAssertFalse(lease.endTake(first), "the live take still holds the model")
        XCTAssertTrue(lease.isOpen(second), "a stale end must not close the live take")
        XCTAssertTrue(lease.endTake(second), "the owed release goes out once no take holds the model")
        XCTAssertFalse(lease.endTake(second), "and not again")
    }

    func testOwedReleaseIsSentOnceWhenTheLastTakeEnds() {
        var lease = SpeakerModelLease()
        let first = UUID(), second = UUID()
        lease.begin(first)
        lease.noteEmbedding(first)
        lease.begin(second)
        XCTAssertTrue(lease.endTake(second), "no take holds the model after second ends, so the owed release is sent")
        XCTAssertFalse(lease.endTake(first), "a stale end afterwards sends nothing")
    }

    func testFinalWhoseEmbeddingHasNotReturnedIsInTheRelease() {
        var transcript = TakeTranscript()
        let index = transcript.land(text: "Hello there.", start: 0, end: 2)
        _ = transcript.release()
        XCTAssertEqual(transcript.releasePaste.map(\.text), ["Hello there."])
        XCTAssertNil(transcript.releasePaste.first?.embedding, "the embedding is still pending")
        transcript.setEmbedding([1, 0], at: index)
        XCTAssertEqual(transcript.releasePaste.map(\.text), ["Hello there."], "the late embedding adds nothing twice")
    }

    func testTailIsTheVolatileAtTheMomentOfRelease() {
        var transcript = TakeTranscript()
        transcript.setVolatile(text: "and then", start: 2, end: 3)
        _ = transcript.release()
        transcript.setVolatile(text: "and then we left", start: 2, end: 4)
        XCTAssertEqual(transcript.releasePaste.last?.text, "and then")
        XCTAssertEqual(transcript.releasePaste.last?.end, 3)
    }

    func testFinalLandingAfterReleaseIsNotDoubledByTheTail() {
        var transcript = TakeTranscript()
        transcript.setVolatile(text: "world", start: 1, end: 2)
        XCTAssertNotNil(transcript.release())
        transcript.setTailEmbedding(nil)
        _ = transcript.land(text: "world", start: 1, end: 2)
        XCTAssertEqual(transcript.segments(finalized: false).map(\.text), ["world"])
    }

    func testUnfinalizedTakeKeepsTheTailWhenNoFinalLanded() {
        var transcript = TakeTranscript()
        transcript.setVolatile(text: "hi", start: 0, end: 1)
        XCTAssertNotNil(transcript.release())
        transcript.setTailEmbedding([1, 0])
        XCTAssertEqual(transcript.segments(finalized: false).map(\.text), ["hi"])
        XCTAssertEqual(transcript.segments(finalized: false).first?.embedding, [1, 0])
    }

    func testFinalizedTakeKeepsEveryFinalAndNoTail() {
        var transcript = TakeTranscript()
        _ = transcript.land(text: "a", start: 0, end: 1)
        transcript.setVolatile(text: "b", start: 1, end: 2)
        _ = transcript.release()
        XCTAssertEqual(transcript.segments(finalized: true).map(\.text), ["a"])
    }

    func testBlankVolatileIsNoTail() {
        var transcript = TakeTranscript()
        transcript.setVolatile(text: "  ", start: 0, end: 1)
        XCTAssertNil(transcript.release())
        XCTAssertTrue(transcript.releasePaste.isEmpty)
    }

    func testEmbeddingFillsTheFinalItBelongsTo() {
        var transcript = TakeTranscript()
        _ = transcript.land(text: "a", start: 0, end: 1)
        let second = transcript.land(text: "b", start: 1, end: 2)
        transcript.setEmbedding([1], at: second)
        XCTAssertNil(transcript.finals[0].embedding)
        XCTAssertEqual(transcript.finals[1].embedding, [1])
    }

    func testNeverAnsweringTailEmbeddingYieldsWithinTheBound() async {
        let started = Date()
        let result = await TakeTranscript.boundedEmbedding(seconds: 0.1) { () async -> [Float]? in
            // Ignores cancellation on purpose: models a helper that never replies.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { cont.resume() }
            }
            return [Float](repeating: 1, count: 256)
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the paste waited past the bound")
    }
}

/// Source pins for the release and lease wiring in the app target, which the Logic package cannot compile. Deleting
/// the note or the release call from the app turns one of these red (#17 U2b).
final class SpeakerU2bWiringTests: XCTestCase {
    private func repoFile(_ rel: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/SpeakerTakeTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func testFinishAndCancelEachReleaseTheHelperModel() throws {
        let session = try repoFile("boringNotch/Voice/SpeechAnalyzerSession.swift")
        let releases = session.components(separatedBy: "await FluidSpeakerEmbedder.shared.release(takeID)").count - 1
        XCTAssertEqual(releases, 2, "finish and cancel must each release the helper's model exactly once")
    }

    func testEveryWindowIsNotedAgainstTheLease() throws {
        let embedder = try repoFile("boringNotch/Voice/FluidSpeakerEmbedder.swift")
        XCTAssertTrue(embedder.contains("self.lease.noteEmbedding(take)"),
            "a window that reaches the helper must mark the take as needing a release")
    }

    func testEmbedderIsClosedToWindowsAfterTheTakeEnds() throws {
        let embedder = try repoFile("boringNotch/Voice/FluidSpeakerEmbedder.swift")
        XCTAssertTrue(embedder.contains("guard self.lease.isOpen(take)"),
            "a window after the take's end must not reach the helper")
    }

    func testEveryTakeOpensTheEmbedder() throws {
        let session = try repoFile("boringNotch/Voice/SpeechAnalyzerSession.swift")
        XCTAssertTrue(session.contains("await FluidSpeakerEmbedder.shared.beginTake(takeID)"),
            "a take must reopen the embedder at start, or it never scores")
    }

    func testTheReleaseReachesTheHelper() throws {
        let embedder = try repoFile("boringNotch/Voice/FluidSpeakerEmbedder.swift")
        XCTAssertTrue(embedder.contains("XPCHelperClient.shared.releaseSpeakerModel()"))
    }
}
