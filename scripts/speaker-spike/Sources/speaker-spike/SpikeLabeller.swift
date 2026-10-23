// Spike copy of the step-6 labeller (#17 U1, SpeakerLabeller.swift in the app). U1 is not on the branch yet,
// so the spike carries the same algorithm under its own names. When U1 lands, delete this file and point
// SpeakerSeq.swift at SpeakerLabeller; the grid constants then move to SpeakerLabeller.Params.default.
import FluidAudio
import Foundation
import VoiceDictationLogic

enum SpikeLabel: Hashable {
    case me, other(Int), unknown
}

/// One STT final in the spike: a time span, its embedding (nil when there is none) and the label it gets.
/// `truth` and `overlap` are ground truth for the grid only; the labeller never reads them.
struct SpikeSegment {
    var start: Double
    var end: Double
    var embedding: [Float]?
    var label: SpikeLabel = .unknown
    var truth: Int = -1
    var overlap: Bool = false
}

struct SpikeParams {
    var clusterSim: Double
    var meSim: Double
    var meMargin: Double
    var shortSeconds: Double = 1.0
}

enum SpikeLabeller {
    /// Disjoint 1.5 s windows (hop = window, the U1 rule). The last window ends at the span's end.
    static func disjointWindows(_ x: [Float]) -> [[Float]] {
        guard !x.isEmpty else { return [] }
        let w = 24_000
        if x.count <= w { return [x] }
        var starts = Array(stride(from: 0, to: x.count - w, by: w))
        starts.append(x.count - w)
        return starts.map { Array(x[$0..<($0 + w)]) }
    }

    /// Repeats `samples` to exactly `count` samples.
    static func tile(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        return (0..<count).map { samples[$0 % samples.count] }
    }

    /// Mean of the embeddings, L2-normalised (same arithmetic as SpeakerGate.centroid, which is internal).
    static func centroid(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Double](repeating: 0, count: first.count)
        for e in embeddings {
            for i in 0..<min(first.count, e.count) { sum[i] += Double(e[i]) }
        }
        let mean = sum.map { $0 / Double(embeddings.count) }
        let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return mean.map { Float($0) } }
        return mean.map { Float($0 / norm) }
    }

    /// Average-linkage agglomerative clustering on cosine. Merge while the best pair's mean similarity is at
    /// least clusterSim. Ties go to the lower index. Clusters come back sorted by their lowest member.
    static func clusters(_ e: [[Float]], clusterSim: Double) -> [[Int]] {
        var cl: [[Int]] = e.indices.map { [$0] }
        func sim(_ a: [Int], _ b: [Int]) -> Double {
            var s = 0.0
            for i in a { for j in b { s += SpeakerGate.cosine(e[i], e[j]) } }
            return s / Double(a.count * b.count)
        }
        while cl.count > 1 {
            var best = -Double.infinity
            var bi = -1
            var bj = -1
            for i in cl.indices {
                for j in cl.indices where j > i {
                    let s = sim(cl[i], cl[j])
                    if s > best {
                        best = s
                        bi = i
                        bj = j
                    }
                }
            }
            guard best >= clusterSim else { break }
            cl[bi] += cl[bj]
            cl[bi].sort()
            cl.remove(at: bj)
        }
        return cl.sorted { $0[0] < $1[0] }
    }

    /// Index of the Me cluster: the highest cosine of its centroid with the voiceprint, if that is at least
    /// meSim and ahead of the runner-up by meMargin. A lone cluster needs only meSim. nil otherwise.
    static func meCluster(_ cl: [[Int]], embeddings: [[Float]], voiceprint: [Float], params: SpikeParams) -> Int? {
        guard !voiceprint.isEmpty, !cl.isEmpty else { return nil }
        let sims = cl.map { members in
            SpeakerGate.cosine(centroid(members.map { embeddings[$0] }), voiceprint)
        }
        let order = sims.indices.sorted { sims[$0] > sims[$1] || (sims[$0] == sims[$1] && $0 < $1) }
        let b = order[0]
        guard sims[b] >= params.meSim else { return nil }
        if cl.count == 1 { return b }
        return sims[b] - sims[order[1]] >= params.meMargin ? b : nil
    }

    /// Full pass at key release. Segments shorter than shortSeconds or without an embedding are not clustered:
    /// they take the previous segment's label in time order, else the next clustered one, else unknown.
    /// Others are numbered 2... by first start (1... with an empty voiceprint, which has no Me).
    static func label(_ segs: [SpikeSegment], voiceprint: [Float], params: SpikeParams) -> [SpikeSegment] {
        var out = segs
        let order = segs.indices.sorted { (segs[$0].start, $0) < (segs[$1].start, $1) }
        let clustered = order.filter { segs[$0].embedding != nil && segs[$0].end - segs[$0].start >= params.shortSeconds }
        let isClustered = Set(clustered)
        let embs = clustered.map { segs[$0].embedding ?? [] }
        let cl = clusters(embs, clusterSim: params.clusterSim)
        let me = meCluster(cl, embeddings: embs, voiceprint: voiceprint, params: params)
        var next = voiceprint.isEmpty ? 1 : 2
        var labelOfCluster: [SpikeLabel] = []
        for ci in cl.indices {
            if ci == me {
                labelOfCluster.append(.me)
            } else {
                labelOfCluster.append(.other(next))
                next += 1
            }
        }
        for (ci, members) in cl.enumerated() {
            for m in members { out[clustered[m]].label = labelOfCluster[ci] }
        }
        for (k, idx) in order.enumerated() where !isClustered.contains(idx) {
            if k > 0, out[order[k - 1]].label != .unknown {
                out[idx].label = out[order[k - 1]].label
            } else if let forward = order.dropFirst(k + 1).first(where: { isClustered.contains($0) }) {
                out[idx].label = out[forward].label
            } else {
                out[idx].label = .unknown
            }
        }
        return out
    }
}

/// Disjoint 1.5 s windows, each tiled to the model's 10 s input, centroid of the window embeddings.
/// The spike's segmentEmbedding for a piece of an offline sequence; embedWindow is the app's extractor path.
func spikeSegmentEmbedding(_ x: [Float]) throws -> [Float]? {
    let embs = try SpikeLabeller.disjointWindows(x)
        .map { try embedWindow(SpikeLabeller.tile($0, to: 160_000)) }
        .filter { !$0.isEmpty }
    return embs.isEmpty ? nil : SpikeLabeller.centroid(embs)
}
