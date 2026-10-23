import Foundation

/// Which speakers a take keeps (#17). Read once, at key release.
public enum SpeakerMode: String, Codable, Sendable {
    /// Lionel only: the fn dictation default.
    case onlyMe
    /// Everyone but Lionel: a lecture, or the other person in a call.
    case everyoneButMe
    /// Everyone, one labelled line per speaker turn.
    case everyoneLabelled
}

/// Who said a segment. `other` numbers start at 2 when there is a voiceprint, at 1 when there is none.
public enum SpeakerLabel: Equatable, Sendable {
    case me
    case other(Int)
    /// No embedding and no neighbour to inherit from. Kept in every mode (fail open).
    case unknown
}

/// One STT final segment with its embedding and, after `SpeakerLabeller.label`, its speaker.
public struct LabelledSegment: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var embedding: [Float]?
    public var label: SpeakerLabel

    public init(text: String, start: Double, end: Double, embedding: [Float]?, label: SpeakerLabel) {
        self.text = text
        self.start = start
        self.end = end
        self.embedding = embedding
        self.label = label
    }
}

/// Relative speaker labelling for one take (#17). Pure Swift: no model, no audio, no Defaults.
/// The segments are clustered on cosine similarity at key release, and the cluster nearest the
/// voiceprint by a margin is Me. Everything else is Speaker 2, 3… by first appearance.
public struct SpeakerLabeller: Sendable {
    public struct Params: Equatable, Sendable {
        /// Average-linkage merge floor for the segments that are not Me one at a time: two clusters merge while
        /// their mean pairwise cosine is at least this.
        public var clusterSim: Double
        /// A segment, or a cluster's centroid, whose cosine with the voiceprint reaches this is Me.
        public var meSim: Double
        /// A cluster rescued into Me must lead every other cluster's cosine with its centroid by at least this,
        /// measured against the Me centroid.
        public var meMargin: Double
        /// A cluster is only rescued into Me if its voiceprint cosine reaches `meSim - rescueSim`.
        public var rescueSim: Double
        /// Segments shorter than this are not clustered and inherit a neighbour's label.
        public var shortSeconds: Double

        public init(clusterSim: Double, meSim: Double, meMargin: Double, rescueSim: Double, shortSeconds: Double) {
            self.clusterSim = clusterSim
            self.meSim = meSim
            self.meMargin = meMargin
            self.rescueSim = rescueSim
            self.shortSeconds = shortSeconds
        }

        /// Placeholder constants until the spike's grid (U0 step 5) sets the real ones.
        public static let `default` = Params(
            clusterSim: 0.40, meSim: 0.30, meMargin: 0.10, rescueSim: 0.15, shortSeconds: 1.0
        )
    }

    /// Average-linkage agglomerative clustering on cosine. Merges the most similar pair while its mean
    /// pairwise cosine is at least `clusterSim`. Ties go to the lower pair of indices. Each cluster lists its
    /// indices ascending, and the clusters are ordered by their lowest index.
    static func clusters(_ embeddings: [[Float]], clusterSim: Double) -> [[Int]] {
        let n = embeddings.count
        var members: [[Int]] = (0..<n).map { [$0] }
        // sums[a][b]: the sum of pairwise cosines between the clusters in slots a and b.
        var sums = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for a in 0..<n {
            for b in (a + 1)..<max(a + 1, n) {
                let s = SpeakerGate.cosine(embeddings[a], embeddings[b])
                sums[a][b] = s
                sums[b][a] = s
            }
        }
        var active = Array(0..<n)
        while active.count > 1 {
            var best: (x: Int, y: Int, sim: Double)?
            for i in active.indices {
                for j in active.indices where j > i {
                    let a = active[i], b = active[j]
                    let sim = sums[a][b] / Double(members[a].count * members[b].count)
                    if best == nil || sim > best!.sim {
                        best = (a, b, sim)
                    }
                }
            }
            guard let merge = best, merge.sim >= clusterSim else { break }
            // The lower slot survives. Slots stay in ascending order, so a slot is its cluster's lowest index.
            members[merge.x] += members[merge.y]
            for k in active where k != merge.x && k != merge.y {
                sums[merge.x][k] += sums[merge.y][k]
                sums[k][merge.x] = sums[merge.x][k]
            }
            active.removeAll { $0 == merge.y }
        }
        return active.map { members[$0].sorted() }
    }

    /// Index into `clusters` of the Me cluster: the one whose centroid is nearest the voiceprint, if its
    /// cosine reaches `meSim` and leads the runner-up by `meMargin`. A lone cluster needs only `meSim`.
    /// nil otherwise, and nil with no voiceprint.
    static func meCluster(
        _ clusters: [[Int]], embeddings: [[Float]], voiceprint: [Float], params: Params
    ) -> Int? {
        guard !voiceprint.isEmpty, !clusters.isEmpty else { return nil }
        let sims = clusters.map { members in
            SpeakerGate.cosine(SpeakerGate.centroid(members.map { embeddings[$0] }), voiceprint)
        }
        let order = sims.indices.sorted { sims[$0] > sims[$1] || (sims[$0] == sims[$1] && $0 < $1) }
        let best = order[0]
        guard sims[best] >= params.meSim else { return nil }
        if order.count > 1 {
            guard sims[best] - sims[order[1]] >= params.meMargin else { return nil }
        }
        return best
    }

    /// Labels every segment (v2, #17 U1). A segment whose embedding reaches `meSim` against the voiceprint is
    /// `.me` on its own. The rest, with an embedding and at least `shortSeconds` long, are clustered, and a
    /// cluster that passes the rescue rule (see step 3) is `.me` too. The other clusters are `.other(n)`,
    /// numbered by each cluster's first start time. Any other segment takes the previous segment's label, else
    /// the next, else `.unknown`. Returns the input order.
    /// With no voiceprint and no embeddings every segment is `.unknown`, which every mode keeps.
    public static func label(_ segments: [LabelledSegment], voiceprint: [Float], params: Params) -> [LabelledSegment] {
        func embedded(_ i: Int) -> [Float]? {
            guard let e = segments[i].embedding, !e.isEmpty else { return nil }
            return e
        }
        // 1. Every segment at or above meSim is Me, one segment at a time. Without a voiceprint, none is.
        var me = Set<Int>()
        if !voiceprint.isEmpty {
            for i in segments.indices {
                if let e = embedded(i), SpeakerGate.cosine(e, voiceprint) >= params.meSim { me.insert(i) }
            }
        }
        let meCentroid: [Float]? = me.isEmpty ? nil : SpeakerGate.centroid(me.sorted().map { embedded($0) ?? [] })

        // 2. The rest with an embedding and long enough are clustered.
        let usable = segments.indices.filter { i in
            !me.contains(i) && embedded(i) != nil
                && max(0, segments[i].end - segments[i].start) >= params.shortSeconds
        }
        let embeddings = usable.map { embedded($0) ?? [] }
        let local = clusters(embeddings, clusterSim: params.clusterSim)
        let centroids = local.map { SpeakerGate.centroid($0.map { embeddings[$0] }) }

        // 3. A cluster that is Me by the rescue rule joins Me. It must sit nearer the Me centroid than every
        // other cluster by meMargin (with no other cluster, the margin is not tested), and reach the
        // voiceprint at meSim - rescueSim. Skipped with no Me centroid.
        var rescued = Set<Int>()
        if let meCentroid, !voiceprint.isEmpty {
            for c in local.indices {
                let toMe = SpeakerGate.cosine(centroids[c], meCentroid)
                let runnerUp = local.indices
                    .filter { $0 != c }
                    .map { SpeakerGate.cosine(centroids[c], centroids[$0]) }
                    .max()
                let leads = runnerUp.map { toMe >= $0 + params.meMargin } ?? true
                if leads, SpeakerGate.cosine(centroids[c], voiceprint) >= params.meSim - params.rescueSim {
                    rescued.insert(c)
                }
            }
        }

        // 4. The other clusters are Speaker 2, 3… (1 with no voiceprint) by their first start.
        let firstStart = { (cluster: [Int]) in cluster.map { segments[usable[$0]].start }.min() ?? 0 }
        let others = local.indices
            .filter { !rescued.contains($0) }
            .sorted { (firstStart(local[$0]), $0) < (firstStart(local[$1]), $1) }

        // Resolved labels, indexed like `segments`. Labelled segments first, then inheritance.
        var resolved = [SpeakerLabel?](repeating: nil, count: segments.count)
        for i in me { resolved[i] = .me }
        for c in rescued {
            for m in local[c] { resolved[usable[m]] = .me }
        }
        var number = voiceprint.isEmpty ? 1 : 2
        for c in others {
            for m in local[c] { resolved[usable[m]] = .other(number) }
            number += 1
        }
        // 5. Segments with no label inherit the previous label, else the next.
        for i in segments.indices where resolved[i] == nil && i > 0 {
            resolved[i] = resolved[i - 1]
        }
        for i in segments.indices.reversed() where resolved[i] == nil && i + 1 < segments.count {
            resolved[i] = resolved[i + 1]
        }
        return segments.indices.map { i in
            var out = segments[i]
            out.label = resolved[i] ?? .unknown
            return out
        }
    }

    /// Whether a label survives a mode. `.unknown` survives every mode.
    private static func keeps(_ label: SpeakerLabel, _ mode: SpeakerMode) -> Bool {
        switch (label, mode) {
        case (.unknown, _), (_, .everyoneLabelled): return true
        case (.me, .onlyMe): return true
        case (.other, .everyoneButMe): return true
        default: return false
        }
    }

    /// The segments a mode keeps, in order.
    public static func kept(_ segments: [LabelledSegment], mode: SpeakerMode) -> [LabelledSegment] {
        segments.filter { keeps($0.label, mode) }
    }

    /// The time ranges of the segments a mode drops, in order. Silence these in the cloud WAV.
    public static func droppedRanges(_ segments: [LabelledSegment], mode: SpeakerMode) -> [ClosedRange<Double>] {
        segments.filter { !keeps($0.label, mode) }.map { min($0.start, $0.end)...max($0.start, $0.end) }
    }

    /// onlyMe and everyoneButMe paste the kept text joined, with no labels. everyoneLabelled pastes one line
    /// per speaker turn: consecutive segments with the same label merge, and each line reads `Me: `,
    /// `Speaker N: ` or `Speaker ?: `. Segments with no text are skipped. Lines join with "\n".
    public static func pasteText(_ segments: [LabelledSegment], mode: SpeakerMode) -> String {
        guard mode == .everyoneLabelled else {
            return TranscriptAssembler.join(kept(segments, mode: mode).map { $0.text })
        }
        var turns: [(label: SpeakerLabel, texts: [String])] = []
        for segment in segments {
            let text = TranscriptAssembler.join([segment.text])
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.label == segment.label {
                turns[turns.count - 1].texts.append(text)
            } else {
                turns.append((segment.label, [text]))
            }
        }
        return turns.map { turn in
            let prefix: String
            switch turn.label {
            case .me: prefix = "Me"
            case .other(let n): prefix = "Speaker \(n)"
            case .unknown: prefix = "Speaker ?"
            }
            return "\(prefix): \(TranscriptAssembler.join(turn.texts))"
        }.joined(separator: "\n")
    }
}
