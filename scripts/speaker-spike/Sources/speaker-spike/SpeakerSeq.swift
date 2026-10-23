// Offline multi-speaker sequences (#17 U0 round 4, --seq), the FluidAudio diarizer row (--diarizer), and the
// STT prompt check (step 1). No mic: every input is a clip on disk or a `say` render.
import FluidAudio
import Foundation
import Speech
import VoiceDictationLogic

/// Truth ids: 0 Me (clip 2 and overlap pieces), 1 Speaker A (clip 5), 2-4 the say voices, 5 Song (clip 3).
let truthNames = ["Me", "Speaker A", "Samantha", "Daniel", "Karen", "Song"]
let seqCount = 24
let seqGapSamples = 4_800  // 0.3 s between pieces
let sttPrompts: [(letter: String, text: String)] = [("A", promptA), ("B", promptB), ("C", promptC)]

struct SeqPiece {
    let truth: Int
    let overlap: Bool
    let start: Int  // sample index into the sequence audio
    let end: Int
}

struct Sequence {
    let audio: [Float]
    let pieces: [SeqPiece]
}

/// Metrics for one labelled set of sequences. Me metrics count every piece; overlap is the overlap pieces.
struct Grid {
    var mePrec: Double
    var meRec: Double
    var exact: Double
    var purity: Double
    var ovlMe: Double
    var f1: Double { mePrec + meRec > 0 ? 2 * mePrec * meRec / (mePrec + meRec) : 0 }
}

func pick(_ rng: inout Lcg, _ n: Int) -> Int {
    guard n > 1 else { return 0 }
    return min(n - 1, Int((rng.next() + 1) / 2 * Double(n)))
}

func fmtPct(_ v: Double) -> String { v.isNaN ? "  n/a" : String(format: "%5.1f%%", v * 100) }

// MARK: - STT prompt check (step 1)

/// WER of clip `name` against each of the three prompts. The transcript text never leaves this function.
@available(macOS 26.0, *)
func sttPromptCheck(_ name: String, converted: Bool) async -> (words: Int, wers: [Double], best: Int, feed: String)? {
    let text: String
    var feed = ""
    do {
        if converted {
            let r = try await appleTranscribeConverted(clipURL(name))
            text = r.text
            feed = "file \(r.file) -> analyzer \(r.analyzer)"
        } else {
            text = try await appleTranscribe(clipURL(name))
        }
    } catch {
        print("STT \(converted ? "converted" : "file") feed \(name) failed: \(error)")
        return nil
    }
    stamp("first STT call")
    let wers = sttPrompts.map { WordErrorRate.wer(reference: $0.text, hypothesis: text) }
    let best = wers.indices.min { wers[$0] < wers[$1] } ?? 0
    return (tokens(text).count, wers, best, feed)
}

// MARK: - Sequence builder (--seq)

/// Piece banks by truth id. Each speaker's clip is cut into equal pieces of at most ~3 s.
func pieceBanks(_ loaded: [LoadedClip]) throws -> [[[Float]]] {
    func clip(_ name: String) throws -> [Float] {
        guard let c = loaded.first(where: { $0.name == name }) else { throw SpikeError.missingClip(name) }
        return c.samples
    }
    func split(_ x: [Float], _ k: Int) -> [[Float]] {
        let n = x.count / k
        return (0..<k).map { Array(x[($0 * n)..<(($0 + 1) * n)]) }
    }
    var out: [[[Float]]] = [split(try clip("clip2"), 3), split(try clip("clip5"), 3)]
    for v in sayVoices {
        let url = scratch.appendingPathComponent("\(v.file).aiff")
        if !FileManager.default.fileExists(atPath: url.path) { try sayClip(voice: v.voice, text: v.text, to: url) }
        let x = SpeakerGate.int16RoundTrip(try loadClip(url))
        let k = max(1, Int((Double(x.count) / (3.0 * sampleRate)).rounded(.up)))
        out.append(split(x, k))
    }
    out.append(split(try clip("clip3"), 3))
    return out
}

/// 24 sequences, LCG-seeded. Sequence s has 2-4 distinct speakers and 6-10 pieces in random order. Every
/// fourth sequence (6 of 24) carries one overlap piece: a Me piece mixed at 0 dB with a say voice, truth Me.
func buildSequences(_ banks: [[[Float]]]) -> [Sequence] {
    let gap = [Float](repeating: 0, count: seqGapSamples)
    var seqs: [Sequence] = []
    for s in 0..<seqCount {
        var rng = Lcg(state: UInt64(1_000 + s))
        let overlapSeq = s % 4 == 3
        let k = 2 + pick(&rng, 3)
        var set: [Int] = overlapSeq ? [0] : []
        while set.count < k {
            let c = pick(&rng, 6)
            if !set.contains(c) { set.append(c) }
        }
        let m = 6 + pick(&rng, 5)
        var order: [Int] = (0..<m).map { $0 < k ? set[$0] : set[pick(&rng, k)] }
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, pick(&rng, i + 1)) }
        var items: [(truth: Int, overlap: Bool)] = order.map { (truth: $0, overlap: false) }
        if overlapSeq { items.insert((truth: 0, overlap: true), at: pick(&rng, items.count + 1)) }

        var audio: [Float] = []
        var pieces: [SeqPiece] = []
        for (idx, item) in items.enumerated() {
            if idx > 0 { audio += gap }
            let piece: [Float]
            if item.overlap {
                let me = banks[0][pick(&rng, banks[0].count)]
                let v = 2 + pick(&rng, 3)
                let say = fit(banks[v][pick(&rng, banks[v].count)], to: me.count)
                let g = snrGain(clean: me, interferer: say, snrDB: 0)
                piece = zip(me, say).map { $0 + g * $1 }
            } else {
                piece = banks[item.truth][pick(&rng, banks[item.truth].count)]
            }
            let start = audio.count
            audio += piece
            pieces.append(SeqPiece(truth: item.truth, overlap: item.overlap, start: start, end: audio.count))
        }
        seqs.append(Sequence(audio: audio, pieces: pieces))
    }
    return seqs
}

// MARK: - Embedding and grading

/// One isolation state: every sequence through the AU (or not), then the Int16 round trip.
func processedSequences(_ seqs: [Sequence], iso: Bool) throws -> [[Float]] {
    try seqs.map { SpeakerGate.int16RoundTrip(iso ? try isolateOffline($0.audio) : $0.audio) }
}

/// One STT final per piece. Returns the segments per sequence and the embedding CPU per audio second.
func embedPieces(_ seqs: [Sequence], audios: [[Float]]) throws -> (segs: [[SpikeSegment]], cpuPerSec: Double) {
    var out: [[SpikeSegment]] = []
    var cpu = 0.0
    var sec = 0.0
    for (i, seq) in seqs.enumerated() {
        var row: [SpikeSegment] = []
        for p in seq.pieces {
            let lo = min(p.start, audios[i].count)
            let hi = min(p.end, audios[i].count)
            let slice = Array(audios[i][lo..<hi])
            let c0 = cpuSeconds()
            let e = try spikeSegmentEmbedding(slice)
            cpu += cpuSeconds() - c0
            sec += Double(slice.count) / sampleRate
            row.append(SpikeSegment(start: Double(p.start) / sampleRate, end: Double(p.end) / sampleRate,
                                    embedding: e, truth: p.truth, overlap: p.overlap))
        }
        out.append(row)
    }
    return (out, sec > 0 ? cpu / sec : 0)
}

func grade(_ seqs: [[SpikeSegment]]) -> Grid {
    var tp = 0, fp = 0, fn = 0, ovl = 0, ovlHit = 0, exact = 0
    var purity = 0.0
    for segs in seqs {
        var groups: [SpikeLabel: [Int: Int]] = [:]
        var predicted = Set<SpikeLabel>()
        for s in segs {
            let predMe = s.label == .me
            let truthMe = s.truth == 0
            if predMe && truthMe { tp += 1 } else if predMe { fp += 1 } else if truthMe { fn += 1 }
            if s.overlap {
                ovl += 1
                if predMe { ovlHit += 1 }
            }
            if s.label != .unknown {
                predicted.insert(s.label)
                groups[s.label, default: [:]][s.truth, default: 0] += 1
            }
        }
        if predicted.count == Set(segs.map(\.truth)).count { exact += 1 }
        let majority = groups.values.reduce(0) { $0 + ($1.values.max() ?? 0) }
        purity += segs.isEmpty ? 0 : Double(majority) / Double(segs.count)
    }
    let n = Double(max(seqs.count, 1))
    return Grid(
        mePrec: tp + fp > 0 ? Double(tp) / Double(tp + fp) : 0,
        meRec: tp + fn > 0 ? Double(tp) / Double(tp + fn) : 0,
        exact: Double(exact) / n,
        purity: purity / n,
        ovlMe: ovl > 0 ? Double(ovlHit) / Double(ovl) : .nan)
}

func gridLine(iso: Bool, cl: Double, me: Double, mg: Double, _ g: Grid) -> String {
    "iso \(iso ? "on " : "off")  cluster \(String(format: "%.2f", cl))  me \(String(format: "%.2f", me))"
        + "  margin \(String(format: "%.2f", mg))  "
        + "Me prec \(fmtPct(g.mePrec))  Me rec \(fmtPct(g.meRec))  count exact \(fmtPct(g.exact))"
        + "  purity \(fmtPct(g.purity))  overlap Me \(fmtPct(g.ovlMe))  F1 \(fmtPct(g.f1))"
}

// MARK: - Diarizer row (--diarizer)

/// FluidAudio DiarizerManager on the whole sequence with the voiceprint as a known speaker. Each piece takes
/// the speaker with the most overlapping seconds. A fresh manager per sequence, so no speaker carries over.
func diarizeSequences(_ seqs: [Sequence], audios: [[Float]], voiceprint: [Float]) throws -> (segs: [[SpikeSegment]], cpuPerSec: Double) {
    var out: [[SpikeSegment]] = []
    var cpu = 0.0
    var sec = 0.0
    for (i, seq) in seqs.enumerated() {
        let dm = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.7, minSpeechDuration: 1.0, minSilenceGap: 0.5))
        dm.initialize(models: models)
        dm.initializeKnownSpeakers([Speaker(id: "Me", name: "Me", currentEmbedding: voiceprint)])
        let c0 = cpuSeconds()
        let result = try dm.performCompleteDiarization(audios[i])
        cpu += cpuSeconds() - c0
        sec += Double(audios[i].count) / sampleRate
        var ids: [String: Int] = [:]
        var row: [SpikeSegment] = []
        for p in seq.pieces {
            let ps = Double(p.start) / sampleRate
            let pe = Double(p.end) / sampleRate
            var acc: [String: Double] = [:]
            for r in result.segments {
                let o = min(Double(r.endTimeSeconds), pe) - max(Double(r.startTimeSeconds), ps)
                if o > 0 { acc[r.speakerId, default: 0] += o }
            }
            var label = SpikeLabel.unknown
            if let top = acc.max(by: { $0.value < $1.value })?.key {
                if top == "Me" {
                    label = .me
                } else {
                    if ids[top] == nil { ids[top] = ids.count + 2 }
                    label = .other(ids[top] ?? 0)
                }
            }
            row.append(SpikeSegment(start: ps, end: pe, embedding: nil, label: label, truth: p.truth, overlap: p.overlap))
        }
        out.append(row)
    }
    return (out, sec > 0 ? cpu / sec : 0)
}

// MARK: - Runner

/// --seq and --diarizer. Both isolation states go through the same sequences; the grid is on iso-on for the gate.
func runOffline(wantSeq: Bool, wantDiarizer: Bool) throws {
    guard let c1 = loaded.first(where: { $0.name == "clip1" }) else { throw SpikeError.missingClip("clip 1") }
    guard let voiceprint = try spikeSegmentEmbedding(c1.samples) else { throw SpikeError.missingClip("clip 1 embedding") }
    let seqs = buildSequences(try pieceBanks(loaded))
    let pieces = seqs.reduce(0) { $0 + $1.pieces.count }
    let overlaps = seqs.reduce(0) { $0 + $1.pieces.filter(\.overlap).count }
    let speakerCounts = seqs.map { Set($0.pieces.map(\.truth)).count }
    print("\nOffline sequences (no mic): \(seqs.count) sequences, \(pieces) pieces, \(overlaps) overlap pieces, "
        + "distinct truth speakers per sequence \(speakerCounts.min() ?? 0)-\(speakerCounts.max() ?? 0)")
    print("Voiceprint: clip 1 through the disjoint-window embedding. Pieces: one STT final each.")

    var isoOnGrid: [(cl: Double, me: Double, mg: Double, grid: Grid)] = []
    var onEmbCPU = Double.nan
    for iso in [false, true] {
        let audios: [[Float]]
        do {
            audios = try processedSequences(seqs, iso: iso)
        } catch {
            print("isolation \(iso ? "ON" : "OFF") not run: \(error)")
            continue
        }
        let emb = try embedPieces(seqs, audios: audios)
        if iso { onEmbCPU = emb.cpuPerSec }
        var byTruth: [Int: [Double]] = [:]
        for row in emb.segs {
            for s in row where !s.overlap {
                if let e = s.embedding { byTruth[s.truth, default: []].append(SpeakerGate.cosine(e, voiceprint)) }
            }
        }
        let medians = truthNames.indices.map { "\(truthNames[$0]) \(fmt(percentile(byTruth[$0] ?? [], 0.5)))" }
        print("\nisolation \(iso ? "ON" : "OFF"): median cosine to voiceprint per speaker (pieces): \(medians.joined(separator: ", "))")
        if wantSeq {
            print("\nGrid, isolation \(iso ? "ON" : "OFF"), embedding \(String(format: "%.4f", emb.cpuPerSec)) CPU s per audio s (disjoint windows)")
            for cl in [0.50, 0.60, 0.70] {
                for me in [0.25, 0.30, 0.35] {
                    for mg in [0.05, 0.10, 0.15] {
                        let params = SpikeParams(clusterSim: cl, meSim: me, meMargin: mg)
                        let labelled = emb.segs.map { SpikeLabeller.label($0, voiceprint: voiceprint, params: params) }
                        let g = grade(labelled)
                        print(gridLine(iso: iso, cl: cl, me: me, mg: mg, g))
                        if iso { isoOnGrid.append((cl, me, mg, g)) }
                    }
                }
            }
        }
        if wantSeq, iso, let t = flagValue("--seqtrace").flatMap({ Int($0) }), emb.segs.indices.contains(t) {
            // One sequence, piece by piece: truth, cosine to the voiceprint, and the label at the default grid point.
            let labelled = SpikeLabeller.label(emb.segs[t], voiceprint: voiceprint,
                                               params: SpikeParams(clusterSim: 0.60, meSim: 0.30, meMargin: 0.10))
            print("\ntrace sequence \(t), isolation ON, cluster 0.60 me 0.30 margin 0.10:")
            for s in labelled {
                let cos = s.embedding.map { SpeakerGate.cosine($0, voiceprint) } ?? .nan
                print("  \(truthNames[s.truth]) overlap \(s.overlap ? "yes" : "no ") "
                    + "\(String(format: "%.1f", s.end - s.start)) s  cos \(fmt(cos))  label \(s.label)")
            }
        }
        if wantDiarizer {
            let d = try diarizeSequences(seqs, audios: audios, voiceprint: voiceprint)
            let g = grade(d.segs)
            stamp("diarizer call")
            print("\ndiarizer iso \(iso ? "ON " : "OFF") (FluidAudio, clustering 0.7): " + "Me prec \(fmtPct(g.mePrec))  Me rec \(fmtPct(g.meRec))  count exact \(fmtPct(g.exact))"
                + "  purity \(fmtPct(g.purity))  overlap Me \(fmtPct(g.ovlMe))  CPU \(String(format: "%.4f", d.cpuPerSec)) s/s"
                + "  RSS after call \(String(format: "%.0f", residentMB())) MB")
        }
    }

    if wantSeq, let best = isoOnGrid.max(by: { $0.grid.f1 < $1.grid.f1 }) {
        let g = best.grid
        print("\nGate (isolation ON, best grid point by Me F1: cluster \(best.cl), me \(best.me), margin \(best.mg))")
        print("  Me precision \(fmtPct(g.mePrec)) \(g.mePrec >= 0.95 ? "PASS" : "FAIL") (>= 95%)")
        print("  Me recall \(fmtPct(g.meRec)) \(g.meRec >= 0.90 ? "PASS" : "FAIL") (>= 90%)")
        print("  speaker count exact \(fmtPct(g.exact)) \(g.exact >= 0.80 ? "PASS" : "FAIL") (>= 80%)")
        print("  overlap pieces labelled Me \(fmtPct(g.ovlMe)) \(g.ovlMe >= 0.70 ? "PASS" : "FAIL") (>= 70%)")
        let passing = isoOnGrid.filter { $0.grid.mePrec >= 0.95 && $0.grid.meRec >= 0.90 && $0.grid.exact >= 0.80 && $0.grid.ovlMe >= 0.70 }
        print("  grid points passing all four: \(passing.isEmpty ? "none" : passing.map { "cl \($0.cl) me \($0.me) mg \($0.mg)" }.joined(separator: "; "))")
        print("  emb s/s \(String(format: "%.4f", onEmbCPU)) \(onEmbCPU <= 0.05 ? "PASS" : "FAIL") (<= 0.05)")
    }
}

/// The RSS for each stage, once each: model load, first embedding, first AU render, first STT call, diarizer call, exit.
func printRSSStages() {
    print("\nRSS MB per stage (resident, first time each stage is reached)")
    for name in ["model load", "first embedding", "first AU render", "first STT call", "diarizer call"] {
        let v = rssStamps.first { $0.name == name }?.mb
        print("  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(v.map { String(format: "%.0f", $0) } ?? "not reached")")
    }
    let exitMB = residentMB()
    print("  \("exit".padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%.0f", exitMB))")
    if let first = rssStamps.first(where: { $0.name == "first embedding" })?.mb {
        print("  first embedding: absolute \(String(format: "%.0f", first)) MB (<= 80: \(first <= 80 ? "PASS" : "FAIL")),"
            + " delta from before load \(String(format: "%.0f", first - rssBefore)) MB (<= 80: \(first - rssBefore <= 80 ? "PASS" : "FAIL"))")
    }
}

// MARK: - STT feed check (step 1): the file as analyzeSequence reads it, against the buffers converted to the
// analyzer's bestAvailableAudioFormat and started through an input sequence.

@available(macOS 26.0, *)
func appleTranscribeConverted(_ url: URL) async throws -> (text: String, file: String, analyzer: String) {
    let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let audio = try AVAudioFile(forReading: url)
    guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        throw SpikeError.conversion("no analyzer format")
    }
    let src = audio.processingFormat
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(audio.length)) else {
        throw SpikeError.conversion("feed buffer")
    }
    try audio.read(into: inBuf)
    let buffer: AVAudioPCMBuffer
    if src.sampleRate == target.sampleRate && src.channelCount == target.channelCount
        && src.commonFormat == target.commonFormat {
        buffer = inBuf
    } else {
        guard let converter = AVAudioConverter(from: src, to: target),
              let out = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * target.sampleRate / src.sampleRate) + 4096)
        else { throw SpikeError.conversion("analyzer converter") }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error || err != nil { throw SpikeError.conversion(err?.localizedDescription ?? "status") }
        buffer = out
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let collector = Task { () -> String in
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }
    try await analyzer.start(inputSequence: stream)
    continuation.yield(AnalyzerInput(buffer: buffer))
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let text = try await collector.value
    return (text, formatText(src), formatText(target))
}
