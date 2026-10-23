// Shared embedding and labelling glue for the spike (#17 U0 round 7). One labeller: U1's SpeakerLabeller from
// VoiceDictationLogic. The normalisation and level below are copies of U1's SpeakerGate.normalise and levelDBFS,
// because those are internal in U1 and the spike is a separate module. They must stay byte-for-byte the same
// arithmetic; the parity line in the output compares them with U1's public segmentEmbedding on me1.
import FluidAudio
import Foundation
import VoiceDictationLogic

/// The say voices of the mix and the --seq sequences, in truth order (Samantha, Daniel, Karen).
let sayVoices: [(file: String, voice: String, text: String)] = [
    ("say-samantha", "Samantha", "The committee approved the new budget after a long discussion about the harbour bridge."),
    ("say-daniel", "Daniel", "Remember to water the plants on the balcony before the weekend, because the forecast says it will be hot."),
    ("say-karen", "Karen", "Our train was delayed twice, so we walked the last few miles along the river to the old market."),
]

/// Set by --normalise: the explicit normalisation step runs before the windows, in the STT, stats and sequence paths.
var normaliseOn = false

/// One STT final in the spike: a time span, its embedding, and the ground truth the grid scores against.
struct SpikeSegment {
    var start: Double
    var end: Double
    var embedding: [Float]?
    var truth: Int
    var overlap: Bool
}

/// Voiced level in dBFS (U1's SpeakerGate.levelDBFS): RMS over 20 ms frames within 30 dB of the loudest frame.
func spikeLevelDBFS(_ samples: [Float]) -> Float {
    var frames: [(rms: Double, from: Int, to: Int)] = []
    var from = 0
    while from < samples.count {
        let to = min(from + 320, samples.count)
        var sum = 0.0
        for i in from..<to { sum += Double(samples[i]) * Double(samples[i]) }
        frames.append(((sum / Double(to - from)).squareRoot(), from, to))
        from = to
    }
    guard let loudest = frames.map({ $0.rms }).max(), loudest > 0 else { return -.infinity }
    let cutoff = loudest * pow(10, Double(-30) / 20)
    var sum = 0.0
    var count = 0
    for frame in frames where frame.rms >= cutoff {
        for i in frame.from..<frame.to { sum += Double(samples[i]) * Double(samples[i]) }
        count += frame.to - frame.from
    }
    guard count > 0, sum > 0 else { return -.infinity }
    return Float(10 * log10(sum / Double(count)))
}

/// U1's SpeakerGate.normalise: gain to -26 dBFS voiced, gain capped at +30 dB, clamped to [-1, 1], spans below
/// -60 dBFS returned unchanged. [] for [].
func spikeNormalise(_ samples: [Float], targetDBFS: Float = -26, floorDBFS: Float = -60) -> [Float] {
    guard !samples.isEmpty else { return [] }
    let level = spikeLevelDBFS(samples)
    guard level >= floorDBFS else { return samples }
    let gain = Float(pow(10, Double(min(targetDBFS - level, 30)) / 20))
    return samples.map { min(max($0 * gain, -1), 1) }
}

/// Disjoint windows (hop = window): 1.5 s, the last one ends at the span's end. A span shorter than a window is one.
func disjointWindows(_ x: [Float], window: Int = 24_000) -> [[Float]] {
    guard !x.isEmpty else { return [] }
    if x.count <= window { return [x] }
    var starts = Array(stride(from: 0, to: x.count - window, by: window))
    starts.append(x.count - window)
    return starts.map { Array(x[$0..<($0 + window)]) }
}

/// Repeats `samples` to exactly `count` samples.
func spikeTile(_ samples: [Float], to count: Int) -> [Float] {
    guard !samples.isEmpty, count > 0 else { return [] }
    return (0..<count).map { samples[$0 % samples.count] }
}

/// Mean of the embeddings, L2-normalised (U1's SpeakerGate.centroid arithmetic).
func spikeCentroid(_ embeddings: [[Float]]) -> [Float] {
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

/// The spike's segment embedding: optional normalisation, disjoint windows, each tiled to `tileSamples`, centroid.
/// `embed` is the extractor under test (the shared diarizer, or a manager made for a memory row).
func spikeEmbedding(_ x: [Float], tileSamples: Int = 160_000, normalise: Bool,
                    embed: ([Float]) throws -> [Float]) throws -> [Float]? {
    let src = normalise ? spikeNormalise(x) : x
    let embs = try disjointWindows(src).map { try embed(spikeTile($0, to: tileSamples)) }.filter { !$0.isEmpty }
    return embs.isEmpty ? nil : spikeCentroid(embs)
}

/// The default-model path used by --seq, --stats and --mix. Normalises inside, as U1's segmentEmbedding does.
func spikeSegmentEmbedding(_ x: [Float]) throws -> [Float]? {
    try spikeEmbedding(x, normalise: true, embed: embedWindow)
}

/// Runs U1's labeller over one sequence of pieces and returns the labels in piece order.
func labelPieces(_ segs: [SpikeSegment], voiceprint: [Float], params: SpeakerLabeller.Params) -> [SpeakerLabel] {
    let input = segs.map {
        LabelledSegment(text: "", start: $0.start, end: $0.end, embedding: $0.embedding, label: .unknown)
    }
    return SpeakerLabeller.label(input, voiceprint: voiceprint, params: params).map(\.label)
}

/// Stable key for grouping labels (SpeakerLabel is Equatable, not Hashable).
func labelKey(_ l: SpeakerLabel) -> String {
    switch l {
    case .me: return "me"
    case .other(let n): return "o\(n)"
    case .unknown: return "u"
    }
}
