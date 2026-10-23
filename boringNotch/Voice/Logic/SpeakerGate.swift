import Foundation

/// One STT final segment after the speaker gate. `kept` decides whether its text is pasted and whether its
/// span is silenced in the cloud WAV.
public struct GatedSegment: Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var kept: Bool
    public var score: Double

    public init(text: String, start: Double, end: Double, kept: Bool, score: Double) {
        self.text = text
        self.start = start
        self.end = end
        self.kept = kept
        self.score = score
    }
}

/// Scores a span of 16 kHz mono samples to a speaker embedding. The app's implementation is FluidAudio's
/// WeSpeaker; tests and the spike pass fakes. nil means the span has no scorable window.
protocol SpeakerEmbedder: AnyObject, Sendable {
    func segmentEmbedding(_ samples16k: [Float]) async throws -> [Float]?
}

/// Segment-level speaker verification (#17). Pure arithmetic: no model, no audio device, no Defaults.
/// The app and the spike both score through `segmentEmbedding`, so the two paths cannot drift.
public struct SpeakerGate: Sendable {
    /// Placeholder until the spike's gate rule (U0 step 5) sets the real value.
    static let defaultThreshold = 0.30
    static let sampleRate = 16_000
    /// 1.5 s windows with no overlap (#17 U1): each STT final is embedded once.
    static let windowSamples = 24_000
    static let hopSamples = 24_000
    static let minSegmentSeconds = 3.0
    /// 20 ms at 16 kHz: the frame `levelDBFS` measures.
    static let levelFrameSamples = 320
    /// Frames more than this far below the loudest are not voiced.
    static let voicedRangeDB: Float = 30
    /// The most gain `normalise` adds.
    static let maxGainDB: Float = 30
    /// 10 s, the model's input window. The spike sets 48 000 for `--tile 3`.
    static var tiledSamples = 160_000

    let voiceprint: [Float]
    let threshold: Double

    /// nil when the gate is off or there is no voiceprint yet.
    static func make(voiceprint: [Double], threshold: Double, enabled: Bool) -> SpeakerGate? {
        guard enabled, !voiceprint.isEmpty else { return nil }
        return SpeakerGate(voiceprint: voiceprint.map { Float($0) }, threshold: threshold)
    }

    /// Cosine similarity. 0 when either vector has zero norm or the lengths differ.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Mean of the embeddings, L2-normalised. [] for no embeddings.
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

    /// Repeats `samples` to exactly `count` samples. [] when there is nothing to repeat.
    static func tile(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        return (0..<count).map { samples[$0 % samples.count] }
    }

    /// 1.5 s windows at a 1.5 s hop, the last one ending at the span's end. A span shorter than one
    /// window is one window. [] for an empty span.
    static func windows(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        if samples.count <= windowSamples { return [samples] }
        var starts = Array(stride(from: 0, to: samples.count - windowSamples, by: hopSamples))
        starts.append(samples.count - windowSamples)
        return starts.map { Array(samples[$0..<($0 + windowSamples)]) }
    }

    /// Voiced level in dBFS: RMS over the 20 ms frames that sit within 30 dB of the loudest frame.
    /// -infinity for an empty or silent span.
    static func levelDBFS(_ samples: [Float]) -> Float {
        var frames: [(rms: Double, from: Int, to: Int)] = []
        var from = 0
        while from < samples.count {
            let to = min(from + levelFrameSamples, samples.count)
            var sum = 0.0
            for i in from..<to { sum += Double(samples[i]) * Double(samples[i]) }
            frames.append(((sum / Double(to - from)).squareRoot(), from, to))
            from = to
        }
        guard let loudest = frames.map({ $0.rms }).max(), loudest > 0 else { return -.infinity }
        let cutoff = loudest * pow(10, Double(-voicedRangeDB) / 20)
        var sum = 0.0
        var count = 0
        for frame in frames where frame.rms >= cutoff {
            for i in frame.from..<frame.to { sum += Double(samples[i]) * Double(samples[i]) }
            count += frame.to - frame.from
        }
        guard count > 0, sum > 0 else { return -.infinity }
        return Float(10 * log10(sum / Double(count)))
    }

    /// Scales a span so its voiced level (`levelDBFS`) reaches `targetDBFS`. Gain is capped at +30 dB, and
    /// samples are clamped to [-1, 1]. A span below `floorDBFS` (silence included) is returned unchanged, so
    /// near-silence is not lifted into noise. [] for [].
    static func normalise(_ samples: [Float], targetDBFS: Float = -26, floorDBFS: Float = -60) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let level = levelDBFS(samples)
        guard level >= floorDBFS else { return samples }
        let gain = Float(pow(10, Double(min(targetDBFS - level, maxGainDB)) / 20))
        return samples.map { min(max($0 * gain, -1), 1) }
    }

    /// The one scoring path: the span is normalised, then the centroid of `embed(tile(window, tiledSamples))`
    /// over its windows. nil for an empty span.
    public static func segmentEmbedding(_ samples: [Float], embed: ([Float]) throws -> [Float]) throws -> [Float]? {
        let embeddings = try windows(normalise(samples))
            .map { try embed(tile($0, to: tiledSamples)) }
            .filter { !$0.isEmpty }
        return embeddings.isEmpty ? nil : centroid(embeddings)
    }

    /// Cosine of the span's segment embedding with the voiceprint. nil when the span is empty.
    public static func score(segment: [Float], voiceprint: [Float], embed: ([Float]) throws -> [Float]) throws -> Double? {
        guard let embedding = try segmentEmbedding(segment, embed: embed) else { return nil }
        return cosine(embedding, voiceprint)
    }

    /// Clamps to [-1, 1] and quantises to Int16 the way TakeAudioBuffer holds audio (truncation), then
    /// back to Float. Scoring the round-tripped samples makes live and replayed takes identical.
    public static func int16RoundTrip(_ samples: [Float]) -> [Float] {
        samples.map { s in
            let clamped = s.isNaN ? 0 : min(max(s, -1), 1)
            return Float(Int16(clamped * 32_767)) / 32_768
        }
    }

    /// Threshold for this speaker: the default, lowered so the lowest of the speaker's own self scores
    /// clears it by 0.10, and never below 0.20. [] returns the default.
    static func calibrate(selfScores: [Double], defaultThreshold: Double) -> Double {
        guard let lowest = selfScores.min() else { return defaultThreshold }
        return max(0.20, min(defaultThreshold, lowest - 0.10))
    }

    /// Pads a span to at least `minSeconds`, symmetrically, and shifts it inside [0, total] at an edge.
    /// Never inverted. A total shorter than `minSeconds` gives the whole of [0, total].
    static func widen(start: Double, end: Double, minSeconds: Double, total: Double) -> (Double, Double) {
        let limit = max(total, 0)
        let s0 = min(max(start, 0), limit)
        let e0 = min(max(end, s0), limit)
        let target = min(minSeconds, limit)
        let need = target - (e0 - s0)
        guard need > 0 else { return (s0, e0) }
        var s = s0 - need / 2
        var e = e0 + need / 2
        if s < 0 {
            e += -s
            s = 0
        }
        if e > limit {
            s -= e - limit
            e = limit
        }
        return (max(0, s), min(e, limit))
    }

    /// Accepts when the embedding's cosine with the voiceprint reaches the threshold.
    func accepts(_ embedding: [Float]) -> Bool {
        SpeakerGate.cosine(embedding, voiceprint) >= threshold
    }

    /// The text of the kept segments, in order.
    static func keptText(_ segments: [GatedSegment]) -> [String] {
        segments.filter { $0.kept }.map { $0.text }
    }

    /// The time ranges of the rejected segments, in order.
    static func rejectedRanges(_ segments: [GatedSegment]) -> [ClosedRange<Double>] {
        segments.filter { !$0.kept }.map { min($0.start, $0.end)...max($0.start, $0.end) }
    }

    /// Zeroes every 16-bit sample whose time (index / sampleRate) lies in a range, and leaves every other
    /// byte as it was. Ranges outside the audio are clamped. A sample is zeroed when
    /// lower * rate <= index <= upper * rate.
    static func silence(pcm16LE: Data, ranges: [ClosedRange<Double>], sampleRate: Int) -> Data {
        guard !ranges.isEmpty else { return pcm16LE }
        var out = Data(pcm16LE)
        let count = out.count / 2
        let rate = Double(sampleRate)
        for range in ranges {
            let lowD = min(max(ceil(range.lowerBound * rate), 0), Double(count))
            let highD = min(max(floor(range.upperBound * rate), -1), Double(count - 1))
            guard highD >= lowD, count > 0 else { continue }
            for n in Int(lowD)...Int(highD) {
                out[2 * n] = 0
                out[2 * n + 1] = 0
            }
        }
        return out
    }
}
