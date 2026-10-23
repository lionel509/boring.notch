import Foundation
import XCTest
@testable import VoiceDictationLogic

/// #17 U1: the relative labeller. Pure arithmetic: clustering, the Me cluster, numbering, the per-mode
/// keep rule, and the paste text.
final class SpeakerLabellerTests: XCTestCase {
    private let params = SpeakerLabeller.Params.default

    private func unit(deg: Double) -> [Float] {
        let r = deg * Double.pi / 180
        return [Float(cos(r)), Float(sin(r))]
    }

    private func seg(
        _ text: String, _ start: Double, _ duration: Double = 1.5,
        emb: [Float]? = nil, label: SpeakerLabel = .unknown
    ) -> LabelledSegment {
        LabelledSegment(text: text, start: start, end: start + duration, embedding: emb, label: label)
    }

    // MARK: clusters

    func testClustersMergeTightGroupsAndKeepSingletons() {
        let embs: [[Float]] = [
            [1, 0, 0], [0.99, 0.1, 0], [0, 1, 0], [0.1, 0.99, 0], [0, 0, 1],
        ]
        XCTAssertEqual(SpeakerLabeller.clusters(embs, clusterSim: 0.6), [[0, 1], [2, 3], [4]])
    }

    func testClusterThresholdIsInclusive() {
        // cos([1,0], [1,1]) = 1/sqrt(2) = 0.7071...
        let embs: [[Float]] = [[1, 0], [1, 1]]
        XCTAssertEqual(SpeakerLabeller.clusters(embs, clusterSim: 0.7), [[0, 1]])
        XCTAssertEqual(SpeakerLabeller.clusters(embs, clusterSim: 0.72), [[0], [1]])
        XCTAssertEqual(SpeakerLabeller.clusters([[1, 0], [1, 0]], clusterSim: 1.0), [[0, 1]])
    }

    func testClusterTiesGoToTheLowerIndexPair() {
        // (0,2) and (1,2) tie at 0.7071. The lower pair (0,2) merges first; the average to {1} is
        // (0 + 0.7071) / 2 = 0.354, below 0.5, so it stops there.
        let embs: [[Float]] = [[1, 0], [0, 1], [1, 1]]
        XCTAssertEqual(SpeakerLabeller.clusters(embs, clusterSim: 0.5), [[0, 2], [1]])
    }

    func testClustersOfNothingIsNothing() {
        XCTAssertEqual(SpeakerLabeller.clusters([], clusterSim: 0.6), [])
    }

    // MARK: meCluster

    func testMeClusterIsTheNearestClusterWhenItLeadsByTheMargin() {
        let v: [Float] = unit(deg: 0)
        let embs: [[Float]] = [unit(deg: 10), unit(deg: 10), unit(deg: 60)]
        XCTAssertEqual(SpeakerLabeller.meCluster([[0, 1], [2]], embeddings: embs, voiceprint: v, params: params), 0)
    }

    func testMeClusterIsNilWhenTheRunnerUpIsTooClose() {
        let v: [Float] = unit(deg: 0)
        let embs: [[Float]] = [unit(deg: 20), unit(deg: 25)]
        XCTAssertNil(SpeakerLabeller.meCluster([[0], [1]], embeddings: embs, voiceprint: v, params: params))
    }

    func testMeClusterIsTheArgmaxWhereverItSits() {
        let v: [Float] = unit(deg: 0)
        let embs: [[Float]] = [unit(deg: 60), unit(deg: 10), unit(deg: 10)]
        XCTAssertEqual(SpeakerLabeller.meCluster([[0], [1, 2]], embeddings: embs, voiceprint: v, params: params), 1)
    }

    func testLoneClusterNeedsOnlyTheFloor() {
        let v: [Float] = unit(deg: 0)
        XCTAssertEqual(SpeakerLabeller.meCluster([[0, 1]], embeddings: [unit(deg: 60), unit(deg: 60)],
                                                 voiceprint: v, params: params), 0)
        XCTAssertNil(SpeakerLabeller.meCluster([[0]], embeddings: [unit(deg: 80)], voiceprint: v, params: params))
    }

    func testMeClusterIsNilWithoutAVoiceprint() {
        XCTAssertNil(SpeakerLabeller.meCluster([[0]], embeddings: [[1, 0]], voiceprint: [], params: params))
    }

    // MARK: label

    func testLabelNumbersOthersByFirstStartAndMeIsNotNumbered() {
        let v: [Float] = [1, 0, 0]
        let segments = [
            seg("a", 5, emb: [0, 1, 0]),
            seg("b", 0, emb: [1, 0, 0]),
            seg("c", 10, emb: [0, 1, 0]),
            seg("d", 2, emb: [0, 0, 1]),
        ]
        let labels = SpeakerLabeller.label(segments, voiceprint: v, params: params).map { $0.label }
        XCTAssertEqual(labels, [.other(3), .me, .other(3), .other(2)])
    }

    func testShortSegmentInheritsThePreviousLabel() {
        let v: [Float] = [1, 0, 0]
        let segments = [
            seg("a", 0, emb: [1, 0, 0]),
            seg("interjection", 1.5, 0.5, emb: [0, 1, 0]),
            seg("b", 2.0, emb: [0, 1, 0]),
        ]
        let labels = SpeakerLabeller.label(segments, voiceprint: v, params: params).map { $0.label }
        XCTAssertEqual(labels, [.me, .me, .other(2)])
    }

    func testMissingEmbeddingTakesThePreviousThenTheNextLabel() {
        let v: [Float] = [1, 0, 0]
        let segments = [
            seg("a", 0),
            seg("b", 1.5, emb: [1, 0, 0]),
            seg("c", 3.0),
            seg("d", 4.5, emb: [0, 1, 0]),
        ]
        let labels = SpeakerLabeller.label(segments, voiceprint: v, params: params).map { $0.label }
        XCTAssertEqual(labels, [.me, .me, .me, .other(2)])
    }

    func testSegmentsWithNoEmbeddingAnywhereStayUnknown() {
        let labels = SpeakerLabeller.label([seg("a", 0), seg("b", 1.5)], voiceprint: [1, 0, 0], params: params)
            .map { $0.label }
        XCTAssertEqual(labels, [.unknown, .unknown])
    }

    func testWithoutAVoiceprintThereIsNoMeAndOthersStartAtOne() {
        let segments = [seg("a", 0, emb: [1, 0, 0]), seg("b", 1.5, emb: [0, 1, 0])]
        let labels = SpeakerLabeller.label(segments, voiceprint: [], params: params).map { $0.label }
        XCTAssertEqual(labels, [.other(1), .other(2)])
    }

    // MARK: label v2 (#17 U1): per-segment Me, rescue merge, numbering

    func testEverySegmentAtOrAboveMeSimIsMeEvenWhenClusteringWouldSplitIt() {
        // y is 0.35 from the voiceprint and 0.35 from x, so the clusters stay apart. Each one is still Me.
        let v: [Float] = [1, 0, 0]
        let segments = [
            seg("x", 0, emb: [1, 0, 0]),
            seg("y", 2, emb: [0.35, 0.9368, 0]),
            seg("z", 4, emb: [0, 0, 1]),
        ]
        let labels = SpeakerLabeller.label(segments, voiceprint: v, params: params).map { $0.label }
        XCTAssertEqual(labels, [.me, .me, .other(2)])
    }

    func testRescueMergesAClusterThatLeadsAndIsCloseEnoughToTheVoiceprint() {
        // a is 0.25 from the voiceprint (under meSim, so not Me per segment), 0.25 from the Me centroid and
        // 0 from b. 0.25 >= 0 + meMargin 0.10 and 0.25 >= meSim - rescueSim 0.15, so a is rescued. b is not.
        let v: [Float] = [1, 0, 0]
        let segments = [
            seg("me", 0, emb: [1, 0, 0]),
            seg("a1", 2, emb: [0.25, 0, 0.968]),
            seg("a2", 4, emb: [0.25, 0, 0.968]),
            seg("b", 6, emb: [0, 1, 0]),
        ]
        let labels = SpeakerLabeller.label(segments, voiceprint: v, params: params).map { $0.label }
        XCTAssertEqual(labels, [.me, .me, .me, .other(2)])
    }

    func testRescueRefusesAClusterThatIsNotClearlyNearerMeThanAnother() {
        // a and b are 0.30 apart, so they stay two clusters. a's cosine with Me (0.25) does not beat its
        // cosine with b (0.30) by meMargin 0.10, and b's cosine with Me is no better than a's, so neither
        // is rescued and they keep their numbers. The rescue is not a bare floor check.
        let v: [Float] = [1, 0, 0]
        let segments = [
            seg("me", 0, emb: [1, 0, 0]),
            seg("a1", 2, emb: [0.25, 0, 0.968]),
            seg("a2", 4, emb: [0.25, 0, 0.968]),
            seg("b", 6, emb: [0.25, 0.937, 0.245]),
        ]
        let labels = SpeakerLabeller.label(segments, voiceprint: v, params: params).map { $0.label }
        XCTAssertEqual(labels, [.me, .other(2), .other(2), .other(3)])
    }

    func testRescueRefusesAClusterFarFromTheVoiceprintEvenWhenItIsNearerMe() {
        // The Me centroid sits at [0.8, 0.6, 0], so the cluster at [0, 0.6, 0.8] is 0.36 from it and
        // nothing else exists. Its cosine with the voiceprint is 0, under meSim - rescueSim, so it stays other.
        let v: [Float] = [1, 0, 0]
        let segments = [
            seg("me", 0, emb: [0.8, 0.6, 0]),
            seg("c1", 2, emb: [0, 0.6, 0.8]),
            seg("c2", 4, emb: [0, 0.6, 0.8]),
        ]
        let labels = SpeakerLabeller.label(segments, voiceprint: v, params: params).map { $0.label }
        XCTAssertEqual(labels, [.me, .other(2), .other(2)])
    }

    // MARK: kept and droppedRanges

    private var mixed: [LabelledSegment] {
        [
            seg("a", 0, 1, label: .me),
            seg("b", 1, 1, label: .other(2)),
            seg("c", 2, 1, label: .unknown),
            seg("d", 3, 1, label: .other(3)),
        ]
    }

    func testKeptFollowsTheMode() {
        XCTAssertEqual(SpeakerLabeller.kept(mixed, mode: .onlyMe).map { $0.text }, ["a", "c"])
        XCTAssertEqual(SpeakerLabeller.kept(mixed, mode: .everyoneButMe).map { $0.text }, ["b", "c", "d"])
        XCTAssertEqual(SpeakerLabeller.kept(mixed, mode: .everyoneLabelled).map { $0.text }, ["a", "b", "c", "d"])
    }

    func testDroppedRangesFollowTheMode() {
        XCTAssertEqual(SpeakerLabeller.droppedRanges(mixed, mode: .onlyMe), [1.0...2.0, 3.0...4.0])
        XCTAssertEqual(SpeakerLabeller.droppedRanges(mixed, mode: .everyoneButMe), [0.0...1.0])
        XCTAssertEqual(SpeakerLabeller.droppedRanges(mixed, mode: .everyoneLabelled), [])
    }

    // MARK: pasteText

    func testPlainModesPasteTheKeptTextJoined() {
        let segments = [
            seg("hello  there ", 0, label: .me),
            seg("dropped", 1, label: .other(2)),
            seg("again", 2, label: .me),
        ]
        XCTAssertEqual(SpeakerLabeller.pasteText(segments, mode: .onlyMe), "hello there again")
        XCTAssertEqual(SpeakerLabeller.pasteText(segments, mode: .everyoneButMe), "dropped")
    }

    func testLabelledModePastesOneLinePerTurnWithConsecutiveTurnsMerged() {
        let segments = [
            seg("hi there", 0, label: .me),
            seg("again", 1, label: .me),
            seg("ok", 2, label: .other(2)),
            seg("", 3, label: .unknown),
            seg("yes", 4, label: .other(2)),
            seg("maybe", 5, label: .unknown),
            seg("thanks", 6, label: .me),
        ]
        XCTAssertEqual(
            SpeakerLabeller.pasteText(segments, mode: .everyoneLabelled),
            "Me: hi there again\nSpeaker 2: ok yes\nSpeaker ?: maybe\nMe: thanks"
        )
    }

    // MARK: invariants

    /// 200 LCG-seeded takes: 0-15 segments with embeddings drawn from 1-4 centres plus noise, a random
    /// mode and voiceprint (one centre, or empty), and random 2 s PCM. The session embeds nothing when
    /// there is no voiceprint and the mode is not labelled, so those takes carry nil embeddings. In every
    /// take: the paste is exactly the kept text in order; silence zeroes exactly the dropped samples; and
    /// with no voiceprint the two plain modes keep everything and the WAV is unchanged.
    func testRandomTakesPasteExactlyTheKeptTextAndSilenceOnlyTheDroppedSamples() {
        var state: UInt64 = 0x5EED_1A7E_1100_0017
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let sr = 16_000
        let frames = 2 * sr
        let modes: [SpeakerMode] = [.onlyMe, .everyoneButMe, .everyoneLabelled]
        for _ in 0..<200 {
            let centres = (0..<(1 + Int(next() * 4))).map { _ in
                (0..<8).map { _ in Float(next() * 2 - 1) }
            }
            let mode = modes[Int(next() * 3)]
            let voiceprint: [Float] = next() < 0.33 ? [] : centres[Int(next() * Double(centres.count))]
            let embeddingsOff = voiceprint.isEmpty && mode != .everyoneLabelled
            let count = Int(next() * 16)
            let segments: [LabelledSegment] = (0..<count).map { i in
                let c = centres[Int(next() * Double(centres.count))]
                let emb = c.map { $0 + Float((next() - 0.5) * 0.1) }
                let start = next() * 2
                return LabelledSegment(
                    text: "w\(i)", start: start, end: start + 0.2 + next() * 1.3,
                    embedding: embeddingsOff ? nil : emb, label: .unknown
                )
            }
            let labelled = SpeakerLabeller.label(segments, voiceprint: voiceprint, params: params)
            let kept = SpeakerLabeller.kept(labelled, mode: mode)
            let dropped = SpeakerLabeller.droppedRanges(labelled, mode: mode)

            if mode == .everyoneLabelled {
                let lines = SpeakerLabeller.pasteText(labelled, mode: mode).components(separatedBy: "\n")
                let words = lines.filter { !$0.isEmpty }.map { line -> String in
                    guard let colon = line.range(of: ": ") else { return line }
                    return String(line[colon.upperBound...])
                }
                XCTAssertEqual(TranscriptAssembler.join(words), TranscriptAssembler.join(labelled.map { $0.text }))
            } else {
                XCTAssertEqual(
                    SpeakerLabeller.pasteText(labelled, mode: mode),
                    TranscriptAssembler.join(kept.map { $0.text })
                )
            }

            var pcm = Data()
            for _ in 0..<(2 * frames) { pcm.append(UInt8(next() * 256)) }
            let out = SpeakerGate.silence(pcm16LE: pcm, ranges: dropped, sampleRate: sr)
            XCTAssertEqual(out.count, pcm.count)
            for n in 0..<frames {
                let zeroed = dropped.contains { $0.lowerBound * Double(sr) <= Double(n) && Double(n) <= $0.upperBound * Double(sr) }
                if zeroed {
                    XCTAssertEqual(out[2 * n], 0)
                    XCTAssertEqual(out[2 * n + 1], 0)
                } else {
                    XCTAssertEqual(out[2 * n], pcm[2 * n])
                    XCTAssertEqual(out[2 * n + 1], pcm[2 * n + 1])
                }
            }
            if voiceprint.isEmpty, mode != .everyoneLabelled {
                XCTAssertEqual(kept.count, labelled.count)
                XCTAssertTrue(dropped.isEmpty)
                XCTAssertEqual(out, pcm)
            }
        }
    }
}
