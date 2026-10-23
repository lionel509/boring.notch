import Foundation
import XCTest
@testable import VoiceDictationLogic

final class SpeakerGateTests: XCTestCase {
    /// Deterministic fake embedder: a 3-vector whose first component is the first sample of the input.
    /// The input is always the model's full 10 s window, so the length is checked too.
    private func fakeEmbed(_ input: [Float]) throws -> [Float] {
        XCTAssertEqual(input.count, SpeakerGate.tiledSamples)
        return [input.first ?? 0, 1, 0]
    }

    private func int16Bytes(_ v: Int16) -> Data {
        var little = v.littleEndian
        return Data(bytes: &little, count: 2)
    }

    // MARK: make

    func testMakeIsNilWhenDisabledOrWithoutVoiceprint() {
        XCTAssertNil(SpeakerGate.make(voiceprint: [], threshold: 0.3, enabled: true))
        XCTAssertNil(SpeakerGate.make(voiceprint: [0.1, 0.2], threshold: 0.3, enabled: false))
        XCTAssertNotNil(SpeakerGate.make(voiceprint: [0.1, 0.2], threshold: 0.3, enabled: true))
    }

    // MARK: cosine, centroid, tile, windows

    func testCosineIsZeroForZeroNorm() {
        XCTAssertEqual(SpeakerGate.cosine([0, 0], [1, 0]), 0)
        XCTAssertEqual(SpeakerGate.cosine([1, 0], [0, 0]), 0)
        XCTAssertEqual(SpeakerGate.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(SpeakerGate.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
    }

    func testCentroidIsNormalisedMean() {
        let c = SpeakerGate.centroid([[3, 0], [0, 3]])
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0], Float(sqrt(0.5)), accuracy: 1e-5)
        XCTAssertEqual(c[1], Float(sqrt(0.5)), accuracy: 1e-5)
        XCTAssertEqual(SpeakerGate.centroid([]), [])
    }

    func testTileRepeatsAndTruncates() {
        XCTAssertEqual(SpeakerGate.tile([1, 2], to: 5), [1, 2, 1, 2, 1])
        XCTAssertEqual(SpeakerGate.tile([1, 2, 3], to: 2), [1, 2])
        XCTAssertEqual(SpeakerGate.tile([], to: 4), [])
    }

    func testWindowsAreOnePointFiveSecondsWithShortSpansAsOneWindow() {
        XCTAssertEqual(SpeakerGate.windows([]), [])
        let short = [Float](repeating: 0.5, count: 8_000)
        XCTAssertEqual(SpeakerGate.windows(short).count, 1)
        XCTAssertEqual(SpeakerGate.windows(short).first?.count, 8_000)
        let three = (0..<48_000).map { Float($0) }
        let windows = SpeakerGate.windows(three)
        XCTAssertTrue(windows.allSatisfy { $0.count == SpeakerGate.windowSamples })
        // Hop is 0.75 s over 3 s: starts 0, 12000, 24000. The last window ends at the span end.
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.last?.last, 47_999)
    }

    // MARK: segmentEmbedding and score

    func testSegmentEmbeddingIsNormalisedMeanOverWindows() throws {
        // Windows start at 0 and 12000 samples; the fake embedder returns their first sample.
        let samples = (0..<36_000).map { Float($0 < 12_000 ? 1 : 0) }
        let e = try SpeakerGate.segmentEmbedding(samples, embed: fakeEmbed)
        let vector = try XCTUnwrap(e)
        XCTAssertEqual(vector.count, 3)
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1, accuracy: 1e-5)
    }

    func testSegmentEmbeddingIsNilForEmptySpan() throws {
        XCTAssertNil(try SpeakerGate.segmentEmbedding([], embed: fakeEmbed))
    }

    func testShortSpanIsTiledAndScoredAsOneWindow() throws {
        var calls = 0
        let e = try SpeakerGate.segmentEmbedding([Float](repeating: 0.25, count: 8_000)) { input in
            calls += 1
            return try self.fakeEmbed(input)
        }
        XCTAssertEqual(calls, 1)
        let vector = try XCTUnwrap(e)
        // Fake embedding [0.25, 1, 0] is L2-normalised by the centroid.
        XCTAssertEqual(vector[0], Float(0.25 / sqrt(1.0625)), accuracy: 1e-5)
        XCTAssertEqual(vector[1], Float(1 / sqrt(1.0625)), accuracy: 1e-5)
    }

    func testScoreIsCosineOfSegmentWithVoiceprint() throws {
        let segment = [Float](repeating: 0.25, count: 8_000)
        let score = try SpeakerGate.score(segment: segment, voiceprint: [1, 0, 0], embed: fakeEmbed)
        XCTAssertEqual(try XCTUnwrap(score), 0.25 / sqrt(1.0625), accuracy: 1e-5)
        XCTAssertNil(try SpeakerGate.score(segment: [], voiceprint: [1, 0, 0], embed: fakeEmbed))
    }

    // MARK: int16RoundTrip

    func testInt16RoundTripClampsAndQuantises() {
        let out = SpeakerGate.int16RoundTrip([2.0, -2.0, 0, 0.5])
        XCTAssertEqual(out[0], 32_767.0 / 32_768.0, accuracy: 1e-7)
        XCTAssertEqual(out[1], -32_767.0 / 32_768.0, accuracy: 1e-7)
        XCTAssertEqual(out[2], 0)
        XCTAssertEqual(out[3], Float(16_383) / 32_768, accuracy: 1e-7)
    }

    /// Truncation moves a sample by at most one LSB per pass, so a second pass is within 1 LSB.
    func testInt16RoundTripDriftsAtMostOneLSBOnRepeat() {
        let input: [Float] = (0..<200).map { Float(sin(Double($0) * 0.37)) }
        let once = SpeakerGate.int16RoundTrip(input)
        let twice = SpeakerGate.int16RoundTrip(once)
        for (a, b) in zip(once, twice) {
            XCTAssertLessThanOrEqual(abs(a - b), 1.0 / 32_768 + 1e-7)
        }
    }

    // MARK: calibrate

    func testCalibrateUsesFloorAndMarginBelowSelfScores() {
        XCTAssertEqual(SpeakerGate.calibrate(selfScores: [], defaultThreshold: 0.3), 0.3)
        XCTAssertEqual(SpeakerGate.calibrate(selfScores: [0.6, 0.7], defaultThreshold: 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(SpeakerGate.calibrate(selfScores: [0.4, 0.5], defaultThreshold: 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(SpeakerGate.calibrate(selfScores: [0.35, 0.5], defaultThreshold: 0.3), 0.25, accuracy: 1e-9)
        XCTAssertEqual(SpeakerGate.calibrate(selfScores: [0.1, 0.5], defaultThreshold: 0.3), 0.20, accuracy: 1e-9)
    }

    // MARK: widen

    func testWidenPadsShortSpansSymmetrically() {
        let (s, e) = SpeakerGate.widen(start: 2, end: 2.5, minSeconds: 3, total: 10)
        // Need is 2.5 s: 1.25 s each side of the 0.5 s span.
        XCTAssertEqual(s, 0.75, accuracy: 1e-9)
        XCTAssertEqual(e, 3.75, accuracy: 1e-9)
    }

    func testWidenShiftsAtEdgesAndNeverInverts() {
        let (s, e) = SpeakerGate.widen(start: 0, end: 0.5, minSeconds: 3, total: 10)
        XCTAssertEqual(s, 0, accuracy: 1e-9)
        XCTAssertEqual(e, 3, accuracy: 1e-9)
        let (s2, e2) = SpeakerGate.widen(start: 9.5, end: 10, minSeconds: 3, total: 10)
        XCTAssertEqual(s2, 7, accuracy: 1e-9)
        XCTAssertEqual(e2, 10, accuracy: 1e-9)
        let (s3, e3) = SpeakerGate.widen(start: 1, end: 0.5, minSeconds: 3, total: 10)
        XCTAssertLessThanOrEqual(s3, e3)
        XCTAssertGreaterThanOrEqual(s3, 0)
        XCTAssertLessThanOrEqual(e3, 10)
        let (s4, e4) = SpeakerGate.widen(start: 0, end: 1, minSeconds: 3, total: 2)
        XCTAssertEqual(s4, 0, accuracy: 1e-9)
        XCTAssertEqual(e4, 2, accuracy: 1e-9)
    }

    // MARK: accepts, keptText, rejectedRanges

    func testAcceptsComparesCosineWithThreshold() {
        let gate = SpeakerGate(voiceprint: [1, 0], threshold: 0.5)
        XCTAssertTrue(gate.accepts([1, 0]))
        XCTAssertTrue(gate.accepts([1, 1]))     // cosine ~0.707
        XCTAssertFalse(gate.accepts([0, 1]))    // cosine 0
    }

    func testKeptTextAndRejectedRangesFollowKeptFlag() {
        let segments = [
            GatedSegment(text: "one", start: 0, end: 1, kept: true, score: 0.9),
            GatedSegment(text: "two", start: 1, end: 2, kept: false, score: 0.1),
            GatedSegment(text: "three", start: 2, end: 3.5, kept: true, score: 0.8),
            GatedSegment(text: "four", start: 4, end: 5, kept: false, score: 0.2),
        ]
        XCTAssertEqual(SpeakerGate.keptText(segments), ["one", "three"])
        XCTAssertEqual(SpeakerGate.rejectedRanges(segments), [1...2, 4...5])
    }

    // MARK: silence

    func testSilenceZeroesOnlyTheRange() {
        // Sample n sits at n / 4 s. The range 0.2...0.3 contains only the sample at 0.25 s (index 1).
        var bytes = Data()
        for v in 1...8 { bytes.append(int16Bytes(Int16(v))) }
        let out = SpeakerGate.silence(pcm16LE: bytes, ranges: [0.2...0.3], sampleRate: 4)
        XCTAssertEqual(out.count, bytes.count)
        let values = (0..<8).map { i -> Int16 in
            out.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 2, as: Int16.self) }
        }
        XCTAssertEqual(values, [1, 0, 3, 4, 5, 6, 7, 8])
    }

    func testSilenceWithNoRangesIsIdentityAndClampsOutOfBounds() {
        let bytes = Data([1, 2, 3, 4, 5, 6])
        XCTAssertEqual(SpeakerGate.silence(pcm16LE: bytes, ranges: [], sampleRate: 16_000), bytes)
        let clamped = SpeakerGate.silence(pcm16LE: bytes, ranges: [-5...100], sampleRate: 16_000)
        XCTAssertEqual(clamped, Data(repeating: 0, count: 6))
    }

    // MARK: invariants over random takes

    /// 200 LCG-seeded takes: 0-12 non-overlapping segments in [0, 2.0] s, random scores and a random
    /// threshold over random 2 s Int16 PCM. Kept text is exactly the accepted texts in order, and
    /// silence zeroes exactly the rejected sample ranges and leaves every other byte.
    func testRandomTakesKeepExactlyTheAcceptedSegmentsAndSilenceOnlyTheRejected() {
        var state: UInt64 = 0x5EED_1234_ABCD_0017
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let sr = 16_000
        let frames = 2 * sr
        for _ in 0..<200 {
            let count = Int(next() * 13)
            // Non-overlapping segments: cut the 2 s span at `count` random points, each sample-centred so
            // no boundary falls exactly on a sample.
            var cuts = (0..<(count * 2)).map { _ in Int(next() * Double(frames - 1)) }.sorted()
            cuts = Array(Set(cuts)).sorted()
            var segments: [GatedSegment] = []
            let threshold = next()
            var rejected: [ClosedRange<Double>] = []
            var kept: [String] = []
            var i = 0
            while i + 1 < cuts.count, segments.count < count {
                let a = cuts[i], b = cuts[i + 1]
                i += 2
                let start = (Double(a) + 0.5) / Double(sr)
                let end = (Double(b) + 0.5) / Double(sr)
                let score = next()
                let isKept = score >= threshold
                let text = "w\(segments.count)"
                segments.append(GatedSegment(text: text, start: start, end: end, kept: isKept, score: score))
                if isKept { kept.append(text) } else { rejected.append(start...end) }
            }
            XCTAssertEqual(SpeakerGate.keptText(segments), kept)
            XCTAssertEqual(SpeakerGate.rejectedRanges(segments), rejected)

            var pcm = Data()
            for _ in 0..<frames {
                let v = Int16(truncatingIfNeeded: Int(next() * 65_535) - 32_768)
                pcm.append(int16Bytes(v))
            }
            let out = SpeakerGate.silence(pcm16LE: pcm, ranges: rejected, sampleRate: sr)
            XCTAssertEqual(out.count, pcm.count)
            var expected = pcm
            for r in rejected {
                for n in 0..<frames {
                    let t = Double(n) / Double(sr)
                    if t >= r.lowerBound && t <= r.upperBound {
                        expected[2 * n] = 0
                        expected[2 * n + 1] = 0
                    }
                }
            }
            XCTAssertEqual(out, expected)
            XCTAssertNil(SpeakerGate.make(voiceprint: [], threshold: threshold, enabled: true))
            XCTAssertEqual(SpeakerGate.silence(pcm16LE: pcm, ranges: [], sampleRate: sr), pcm)
        }
    }
}
