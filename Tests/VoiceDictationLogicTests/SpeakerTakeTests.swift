import XCTest
@testable import VoiceDictationLogic

/// The take's speaker bookkeeping (#17 U2b fix round): the lease that closes at the take's end, the transcript that
/// keeps every final in place while its embedding is pending, and the bounded wait for the tail's embedding.
final class SpeakerTakeTests: XCTestCase {
    func testLeaseIsClosedUntilTheTakeBegins() {
        var lease = SpeakerModelLease()
        XCTAssertFalse(lease.isOpen)
        lease.begin()
        XCTAssertTrue(lease.isOpen)
    }

    func testLeaseClosesWhenTheTakeEndsAndReopensOnTheNextBegin() {
        var lease = SpeakerModelLease()
        lease.begin()
        lease.noteEmbedding()
        XCTAssertTrue(lease.endTake(), "a take that embedded must release")
        XCTAssertFalse(lease.isOpen, "a window after the take's end must find the lease closed")
        lease.begin()
        XCTAssertTrue(lease.isOpen)
        XCTAssertFalse(lease.endTake(), "a take that never embedded releases nothing")
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
        let releases = session.components(separatedBy: "await FluidSpeakerEmbedder.shared.release()").count - 1
        XCTAssertEqual(releases, 2, "finish and cancel must each release the helper's model exactly once")
    }

    func testEveryWindowIsNotedAgainstTheLease() throws {
        let embedder = try repoFile("boringNotch/Voice/FluidSpeakerEmbedder.swift")
        XCTAssertTrue(embedder.contains("self.lease.noteEmbedding()"),
            "a window that reaches the helper must mark the take as needing a release")
    }

    func testEmbedderIsClosedToWindowsAfterTheTakeEnds() throws {
        let embedder = try repoFile("boringNotch/Voice/FluidSpeakerEmbedder.swift")
        XCTAssertTrue(embedder.contains("guard self.lease.isOpen"),
            "a window after the take's end must not reach the helper")
    }

    func testEveryTakeOpensTheEmbedder() throws {
        let session = try repoFile("boringNotch/Voice/SpeechAnalyzerSession.swift")
        XCTAssertTrue(session.contains("await FluidSpeakerEmbedder.shared.beginTake()"),
            "a take must reopen the embedder at start, or it never scores")
    }

    func testTheReleaseReachesTheHelper() throws {
        let embedder = try repoFile("boringNotch/Voice/FluidSpeakerEmbedder.swift")
        XCTAssertTrue(embedder.contains("XPCHelperClient.shared.releaseSpeakerModel()"))
    }
}
