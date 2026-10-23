// Offline multi-speaker sequences (--seq), per-piece stats and the normalisation report (--normalise), the
// FluidAudio diarizer row (--diarizer), and the STT prompt check. No mic: every input is a clip on disk or a `say` render.
import FluidAudio
import Foundation
import Speech
import VoiceDictationLogic

/// Truth ids: 0 Me (me2, me3 and overlap pieces), 1 Song (clip 3), 2-4 Speaker 2, 3, 4 (say voices), 5 Noise.
let truthNames = ["Me", "Song", "Speaker 2", "Speaker 3", "Speaker 4", "Noise"]
let noiseTruth = 5
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

/// One labelled piece, ready for grading.
struct Labelled {
    let label: SpeakerLabel
    let truth: Int
    let overlap: Bool
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

// MARK: - STT

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

/// Lionel's speech: me2 then me3, with the 0.3 s gap between them. Normalised when --normalise is set.
func meSpeechSamples(_ loaded: [LoadedClip]) throws -> [Float] {
    func clip(_ name: String) throws -> [Float] {
        guard let c = loaded.first(where: { $0.name == name }) else { throw SpikeError.missingClip(name) }
        return c.samples
    }
    let raw = try clip("me2") + [Float](repeating: 0, count: seqGapSamples) + clip("me3")
    return normaliseOn ? spikeNormalise(raw) : raw
}

/// Scales x to the target RMS in dBFS (the level-match step: interferers to the speech level).
func levelMatch(_ x: [Float], toDBFS target: Double) -> [Float] {
    let cur = rmsDBFS(x)
    guard cur > -120 else { return x }
    let g = Float(pow(10, (target - cur) / 20))
    return x.map { $0 * g }
}

/// Piece banks by truth id: Me (me2 and me3, 3 pieces each), Song (clip 3), the three say voices (level-matched to
/// the speech), Noise (brown, level-matched). Each source is cut into equal pieces of about 2.7 s. With `normalise`,
/// every piece goes through spikeNormalise before it is used.
func pieceBanks(_ loaded: [LoadedClip], normalise: Bool) throws -> [[[Float]]] {
    func clip(_ name: String) throws -> [Float] {
        guard let c = loaded.first(where: { $0.name == name }) else { throw SpikeError.missingClip(name) }
        return c.samples
    }
    func split(_ x: [Float], _ k: Int) -> [[Float]] {
        let n = x.count / k
        let pieces = (0..<k).map { Array(x[($0 * n)..<(($0 + 1) * n)]) }
        return normalise ? pieces.map { spikeNormalise($0) } : pieces
    }
    let rawSpeech = try clip("me2") + [Float](repeating: 0, count: seqGapSamples) + clip("me3")
    let level = rmsDBFS(rawSpeech)
    var out: [[[Float]]] = [split(try clip("me2"), 3) + split(try clip("me3"), 3)]
    out.append(split(try clip("clip3"), 3))
    for v in sayVoices {
        let url = scratch.appendingPathComponent("\(v.file).aiff")
        if !FileManager.default.fileExists(atPath: url.path) { try sayClip(voice: v.voice, text: v.text, to: url) }
        let x = levelMatch(SpeakerGate.int16RoundTrip(try loadClip(url)), toDBFS: level)
        let k = max(1, Int((Double(x.count) / (3.0 * sampleRate)).rounded(.up)))
        out.append(split(x, k))
    }
    out.append(split(levelMatch(brownNoise(3 * 43_200, seed: 7), toDBFS: level), 3))
    return out
}

// MARK: - Sequence builder

/// 24 sequences, LCG-seeded. Sequence s has 2-4 distinct speakers and 6-10 pieces in random order. Every fourth
/// sequence (6 of 24) carries one overlap piece: a Me piece mixed with a say voice at `overlapSNR` dB, truth Me.
/// Every third sequence (s % 3 == 1) carries one noise piece, which is not a speaker.
func buildSequences(_ banks: [[[Float]]], overlapSNR: Double) -> [Sequence] {
    let gap = [Float](repeating: 0, count: seqGapSamples)
    var seqs: [Sequence] = []
    for s in 0..<seqCount {
        var rng = Lcg(state: UInt64(1_000 + s))
        let overlapSeq = s % 4 == 3
        let k = 2 + pick(&rng, 3)
        var set: [Int] = overlapSeq ? [0] : []
        while set.count < k {
            let c = pick(&rng, 5)
            if !set.contains(c) { set.append(c) }
        }
        let m = 6 + pick(&rng, 5)
        var order: [Int] = (0..<m).map { $0 < k ? set[$0] : set[pick(&rng, k)] }
        for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, pick(&rng, i + 1)) }
        var items: [(truth: Int, overlap: Bool)] = order.map { (truth: $0, overlap: false) }
        if overlapSeq { items.insert((truth: 0, overlap: true), at: pick(&rng, items.count + 1)) }
        if s % 3 == 1 { items.insert((truth: noiseTruth, overlap: false), at: pick(&rng, items.count + 1)) }

        var audio: [Float] = []
        var pieces: [SeqPiece] = []
        for (idx, item) in items.enumerated() {
            if idx > 0 { audio += gap }
            let piece: [Float]
            if item.overlap {
                let me = banks[0][pick(&rng, banks[0].count)]
                let v = 2 + pick(&rng, 3)
                let say = fit(banks[v][pick(&rng, banks[v].count)], to: me.count)
                let g = snrGain(clean: me, interferer: say, snrDB: overlapSNR)
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

/// One STT final per piece. Returns the segments per sequence, the embedding CPU per audio second, and the CPU
/// percentage of one core over the wall time of the pass.
func embedPieces(_ seqs: [Sequence], audios: [[Float]]) throws -> (segs: [[SpikeSegment]], cpuPerSec: Double, cpuPct: Double) {
    var out: [[SpikeSegment]] = []
    var cpu = 0.0
    var sec = 0.0
    let wall0 = ProcessInfo.processInfo.systemUptime
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
    let wall = ProcessInfo.processInfo.systemUptime - wall0
    return (out, sec > 0 ? cpu / sec : 0, wall > 0 ? cpu / wall * 100 : 0)
}

func grade(_ seqs: [[Labelled]]) -> Grid {
    var tp = 0, fp = 0, fn = 0, ovl = 0, ovlHit = 0, exact = 0
    var purity = 0.0
    for segs in seqs {
        var groups: [String: [Int: Int]] = [:]
        var predicted = Set<String>()
        for s in segs {
            let predMe = s.label == .me
            let truthMe = s.truth == 0
            if predMe && truthMe { tp += 1 } else if predMe { fp += 1 } else if truthMe { fn += 1 }
            if s.overlap {
                ovl += 1
                if predMe { ovlHit += 1 }
            }
            if s.label != .unknown {
                let k = labelKey(s.label)
                predicted.insert(k)
                groups[k, default: [:]][s.truth, default: 0] += 1
            }
        }
        if predicted.count == Set(segs.map(\.truth).filter { $0 != noiseTruth }).count { exact += 1 }
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

func gridLine(iso: Bool, cl: Double, me: Double, mg: Double, rs: Double, _ g: Grid) -> String {
    "iso \(iso ? "on " : "off")  cluster \(String(format: "%.2f", cl))  meSim \(String(format: "%.2f", me))"
        + "  margin \(String(format: "%.2f", mg))  rescue \(String(format: "%.2f", rs))  "
        + "Me prec \(fmtPct(g.mePrec))  Me rec \(fmtPct(g.meRec))  count exact \(fmtPct(g.exact))"
        + "  purity \(fmtPct(g.purity))  overlap Me \(fmtPct(g.ovlMe))  F1 \(fmtPct(g.f1))"
}

// MARK: - Per-piece stats (plan step 4) and meSim

/// cos(piece, voiceprint) for every Me piece (me2 + me3) and every other speaker's pieces, isolation off and on.
/// Prints min / median / max per group and returns meSim per isolation state: the midpoint of the Me minimum and
/// the others' maximum, to 2 dp. `normalise` sets the explicit normalisation step for the voiceprint and the pieces.
func runStats(loaded: [LoadedClip], normalise: Bool) throws -> [Bool: Double] {
    guard let me1 = loaded.first(where: { $0.name == "me1" }) else { throw SpikeError.missingClip("me1") }
    guard let vp = try spikeEmbedding(me1.samples, normalise: normalise, embed: embedWindow) else {
        throw SpikeError.missingClip("me1 embedding")
    }
    if normalise, let pub = try SpeakerGate.segmentEmbedding(me1.samples, embed: embedWindow) {
        let d = zip(pub, vp).map { abs(Double($0) - Double($1)) }.max() ?? 0
        print("parity: spike embedding vs U1 segmentEmbedding on me1, max abs difference \(String(format: "%.2e", d))")
    }
    let banks = try pieceBanks(loaded, normalise: normalise)
    let groups: [(name: String, bank: Int)] = [("Me", 0), ("Song", 1), ("Speaker 2", 2), ("Speaker 3", 3), ("Speaker 4", 4)]
    print("\nPer-piece cosine to the voiceprint (me1), normalise \(normalise ? "ON" : "OFF"):")
    print("  iso  group       n     min  median     max")
    var meSim: [Bool: Double] = [:]
    for iso in [false, true] {
        var cosByGroup: [String: [Double]] = [:]
        for g in groups {
            for piece in banks[g.bank] {
                let x = SpeakerGate.int16RoundTrip(iso ? try isolateOffline(piece) : piece)
                if let e = try spikeEmbedding(x, normalise: normalise, embed: embedWindow) {
                    cosByGroup[g.name, default: []].append(SpeakerGate.cosine(e, vp))
                }
            }
        }
        for g in groups {
            let v = cosByGroup[g.name] ?? []
            print("  \(iso ? "on " : "off")  \(g.name.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "\(String(format: "%3d", v.count))  \(fmt(v.min() ?? .nan))  \(fmt(percentile(v, 0.5)))  \(fmt(v.max() ?? .nan))")
        }
        let meMin = cosByGroup["Me"]?.min() ?? .nan
        let others = groups.dropFirst().compactMap { cosByGroup[$0.name]?.max() }.max() ?? .nan
        let mid = ((meMin + others) / 2 * 100).rounded() / 100
        meSim[iso] = mid
        print("  iso \(iso ? "on" : "off"): Me min \(fmt(meMin)), others max \(fmt(others)), meSim midpoint \(String(format: "%.2f", mid))")
    }
    return meSim
}

/// Clean STT WER per voice clip, raw and normalised, against its own prompt (plan step 3). The transcript never prints.
@available(macOS 26.0, *)
func runNormaliseReport(loaded: [LoadedClip]) async throws {
    print("\nClean WER per voice clip, raw vs normalised (target -26 dBFS voiced):")
    let prompts: [(name: String, text: String)] = [("me1", promptA), ("me2", promptB), ("me3", promptC)]
    for p in prompts {
        guard let c = loaded.first(where: { $0.name == p.name }) else { continue }
        let raw = try await appleTranscribe(clipURL(p.name))
        let rawWER = WordErrorRate.wer(reference: p.text, hypothesis: raw)
        let norm = spikeNormalise(c.samples)
        let url = scratch.appendingPathComponent("norm-\(p.name).wav")
        try saveClip(norm, to: url)
        let nText = try await appleTranscribe(url)
        let normWER = WordErrorRate.wer(reference: p.text, hypothesis: nText)
        print("  \(p.name): WER raw \(fmt(rawWER)) (level \(String(format: "%.1f", rmsDBFS(c.samples))) dBFS)"
            + "  normalised \(fmt(normWER)) (level \(String(format: "%.1f", Double(spikeLevelDBFS(norm)))) dBFS)")
    }
}

// MARK: - Diarizer row (--diarizer)

/// FluidAudio DiarizerManager on the whole sequence with the voiceprint as a known speaker. Each piece takes the
/// speaker with the most overlapping seconds. A fresh manager per sequence, so no speaker carries over.
func diarizeSequences(_ seqs: [Sequence], audios: [[Float]], voiceprint: [Float]) throws -> (segs: [[Labelled]], cpuPerSec: Double, cpuPct: Double) {
    var out: [[Labelled]] = []
    var cpu = 0.0
    var sec = 0.0
    let wall0 = ProcessInfo.processInfo.systemUptime
    for (i, seq) in seqs.enumerated() {
        let dm = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.7, minSpeechDuration: 1.0, minSilenceGap: 0.5))
        dm.initialize(models: models)
        dm.initializeKnownSpeakers([Speaker(id: "Me", name: "Me", currentEmbedding: voiceprint)])
        let c0 = cpuSeconds()
        let result = try dm.performCompleteDiarization(audios[i])
        cpu += cpuSeconds() - c0
        sec += Double(audios[i].count) / sampleRate
        var ids: [String: Int] = [:]
        var row: [Labelled] = []
        for p in seq.pieces {
            let ps = Double(p.start) / sampleRate
            let pe = Double(p.end) / sampleRate
            var acc: [String: Double] = [:]
            for r in result.segments {
                let o = min(Double(r.endTimeSeconds), pe) - max(Double(r.startTimeSeconds), ps)
                if o > 0 { acc[r.speakerId, default: 0] += o }
            }
            var label = SpeakerLabel.unknown
            if let top = acc.max(by: { $0.value < $1.value })?.key {
                if top == "Me" {
                    label = .me
                } else {
                    if ids[top] == nil { ids[top] = ids.count + 2 }
                    label = .other(ids[top] ?? 0)
                }
            }
            row.append(Labelled(label: label, truth: p.truth, overlap: p.overlap))
        }
        out.append(row)
    }
    let wall = ProcessInfo.processInfo.systemUptime - wall0
    return (out, sec > 0 ? cpu / sec : 0, wall > 0 ? cpu / wall * 100 : 0)
}

// MARK: - Runner

/// --seq and --diarizer. Overlap pieces at +10, +5 and 0 dB; the gated set is +10 dB, isolation ON.
func runOffline(loaded: [LoadedClip], wantSeq: Bool, wantDiarizer: Bool) throws {
    guard let c1 = loaded.first(where: { $0.name == "me1" }) else { throw SpikeError.missingClip("me1") }
    guard let voiceprint = try spikeSegmentEmbedding(c1.samples) else { throw SpikeError.missingClip("me1 embedding") }
    let meSims = try runStats(loaded: loaded, normalise: normaliseOn)
    let banks = try pieceBanks(loaded, normalise: normaliseOn)

    var gateRows: [(snr: Double, iso: Bool, cl: Double, me: Double, mg: Double, rs: Double, grid: Grid)] = []
    for snr in [10.0, 5.0, 0.0] {
        let seqs = buildSequences(banks, overlapSNR: snr)
        let pieces = seqs.reduce(0) { $0 + $1.pieces.count }
        let overlaps = seqs.reduce(0) { $0 + $1.pieces.filter(\.overlap).count }
        let speakerCounts = seqs.map { Set($0.pieces.map(\.truth).filter { $0 != noiseTruth }).count }
        print("\nSequences, overlap at \(Int(snr)) dB (no mic): \(seqs.count) sequences, \(pieces) pieces, "
            + "\(overlaps) overlap pieces, speakers per sequence \(speakerCounts.min() ?? 0)-\(speakerCounts.max() ?? 0)")
        for iso in [false, true] {
            let audios: [[Float]]
            do {
                audios = try processedSequences(seqs, iso: iso)
            } catch {
                print("isolation \(iso ? "ON" : "OFF") not run: \(error)")
                continue
            }
            let emb = try embedPieces(seqs, audios: audios)
            print("embedding pass, overlap \(Int(snr)) dB, isolation \(iso ? "ON" : "OFF"): "
                + "\(String(format: "%.4f", emb.cpuPerSec)) CPU s per audio s, \(String(format: "%.1f", emb.cpuPct))% of one core")
            if wantSeq, let m = meSims[iso] {
                let meGrid = [m - 0.05, m, m + 0.05].map { ($0 * 100).rounded() / 100 }
                for cl in [0.35, 0.40, 0.45, 0.50] {
                    for me in meGrid {
                        for mg in [0.05, 0.10] {
                            for rs in [0.10, 0.15] {
                                let params = SpeakerLabeller.Params(clusterSim: cl, meSim: me, meMargin: mg,
                                                                    rescueSim: rs, shortSeconds: 1.0)
                                let labelled: [[Labelled]] = emb.segs.map { row in
                                    let labels = labelPieces(row, voiceprint: voiceprint, params: params)
                                    return zip(labels, row).map { Labelled(label: $0.0, truth: $0.1.truth, overlap: $0.1.overlap) }
                                }
                                let g = grade(labelled)
                                print(gridLine(iso: iso, cl: cl, me: me, mg: mg, rs: rs, g))
                                gateRows.append((snr, iso, cl, me, mg, rs, g))
                            }
                        }
                    }
                }
            }
            if wantDiarizer && snr == 10.0 {
                let d = try diarizeSequences(seqs, audios: audios, voiceprint: voiceprint)
                let g = grade(d.segs)
                stamp("diarizer call")
                print("\ndiarizer iso \(iso ? "ON " : "OFF") (FluidAudio, clustering 0.7), overlap 10 dB: "
                    + "Me prec \(fmtPct(g.mePrec))  Me rec \(fmtPct(g.meRec))  count exact \(fmtPct(g.exact))"
                    + "  purity \(fmtPct(g.purity))  overlap Me \(fmtPct(g.ovlMe))"
                    + "  CPU \(String(format: "%.4f", d.cpuPerSec)) s/s (\(String(format: "%.1f", d.cpuPct))% of one core)"
                    + "  RSS after call \(String(format: "%.0f", residentMB())) MB")
            }
        }
    }

    if wantSeq {
        print("\nBest grid point per overlap level and isolation state (by Me F1):")
        for snr in [10.0, 5.0, 0.0] {
            for iso in [false, true] {
                let rows = gateRows.filter { $0.snr == snr && $0.iso == iso }
                guard let b = rows.max(by: { $0.grid.f1 < $1.grid.f1 }) else { continue }
                print("  overlap \(Int(snr)) dB, iso \(iso ? "ON " : "OFF"): "
                    + gridLine(iso: iso, cl: b.cl, me: b.me, mg: b.mg, rs: b.rs, b.grid))
            }
        }
        print("\nGated set: overlap 10 dB, isolation ON, every grid point:")
        for r in gateRows where r.snr == 10.0 && r.iso {
            print(gridLine(iso: r.iso, cl: r.cl, me: r.me, mg: r.mg, rs: r.rs, r.grid))
        }
    }
}

/// RSS for each stage, once each: model load, first embedding, first AU render, first STT call, diarizer call, exit.
func printRSSStages() {
    print("\nRSS MB per stage (resident, first time each stage is reached)")
    for name in ["model load", "first embedding", "first AU render", "first STT call", "diarizer call"] {
        let v = rssStamps.first { $0.name == name }?.mb
        print("  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(v.map { String(format: "%.0f", $0) } ?? "not reached")")
    }
    print("  \("exit".padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%.0f", residentMB()))")
}

// MARK: - Converted STT feed (step 1 check)

/// The file as analyzeSequence reads it, against the buffers converted to the analyzer's bestAvailableAudioFormat
/// and started through an input sequence.
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
