import XCTest
@testable import VoiceDictationLogic

/// Breaker tests adopted from the PR #26 breaker round (#17 U2b, head f2441fd). Each `testBreak...` pins an
/// invariant the head violated; each one is red until the fix round lands.
final class BreakerSpeakerU2bTests: XCTestCase {
    private func repoFile(_ rel: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/BreakerSpeakerU2bTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    final class Counter: @unchecked Sendable {
        var calls = 0
    }

    /// A cancelled span stops asking the helper for windows. The async `SpeakerGate.segmentEmbedding` loops over
    /// every window with no cancellation check, so windows after a cancel reload the helper's model.
    /// Invariant: a cancelled span stops asking the helper for more windows.
    func testBreakCancelStopsRemainingWindows() async throws {
        let samples = [Float](repeating: 0.1, count: SpeakerGate.windowSamples * 4)
        let counter = Counter()
        let task = Task {
            try await SpeakerGate.segmentEmbedding(samples) { (window: [Float]) async throws -> [Float] in
                counter.calls += 1
                // Not cancellable on purpose: models an XPC reply that ignores Task cancellation.
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cont.resume() }
                }
                return [Float](repeating: 0.5, count: 256)
            }
        }
        // Cancel while the first window is in flight.
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThanOrEqual(counter.calls, 1,
            "a cancelled span kept embedding windows: \(counter.calls) of 4 asked the helper")
    }

    /// `SpeakerWire.embedding` checks only the count. A 256-float NaN reply passes, cosine returns 0 for it, and
    /// the segment is dropped in onlyMe. Invariant: a non-finite reply is no embedding (nil), so the caller keeps it.
    func testBreakNaNEmbeddingReplyIsRejected() {
        let nan = SpeakerWire.pack([Float](repeating: .nan, count: 256))
        XCTAssertNil(SpeakerWire.embedding(from: nan), "a 256-float NaN reply was accepted as an embedding")
    }

    /// Same invariant as the NaN case, with +inf.
    func testBreakInfiniteEmbeddingReplyIsRejected() {
        let inf = SpeakerWire.pack([Float](repeating: .infinity, count: 256))
        XCTAssertNil(SpeakerWire.embedding(from: inf), "a 256-float +inf reply was accepted as an embedding")
    }

    /// A silent take prints `level=-inf`, which is not a dBFS number and breaks any parse of the take line.
    /// Invariant: every `level=` value is a finite number or the token `none`.
    func testBreakSilentTakeLevelIsNotInf() {
        var report = TakeReport()
        report.level = SpeakerGate.levelDBFS([Float](repeating: 0, count: 16_000))
        let line = report.line
        XCTAssertFalse(line.contains("level=-inf"), "silent take printed a non-number level: \(line)")
    }

    /// `rssIdleMB` defaults to -1, so an unset idle sample prints the same `idle=-1` as a real -1 MB change.
    /// Invariant: an unset idle sample does not print as a number.
    func testBreakUnsetIdleIsNotPrintedAsANumber() {
        var report = TakeReport()
        report.speakerMode = .onlyMe
        XCTAssertFalse(report.line.contains("idle=-1"),
            "an unset idle sample prints idle=-1, the same token as a real -1 MB measurement: \(report.line)")
    }

    /// Source pin, stopgap. The helper's `releaseSpeakerModel` starts an unstructured Task, so the release can run
    /// before an in-flight embed. The helper target cannot see the Logic package, so this stays a source check.
    /// Invariant: the release is queued behind the embeds it follows.
    func testBreakHelperReleaseIsOrderedAfterEmbeds() throws {
        let helper = try repoFile("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        let releaseBody = helper.components(separatedBy: "@objc func releaseSpeakerModel()").last ?? ""
        XCTAssertFalse(releaseBody.prefix(200).contains("Task {"),
            "releaseSpeakerModel starts an unordered Task, so it can run before an in-flight embed and leave the model loaded")
    }
}
