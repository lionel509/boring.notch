// --memory (#17 U0 round 7, plan step 2): one embedder configuration per process, so each RSS number belongs to one
// configuration. Loads the bundles through DiarizerModels.load(localSegmentationModel:localEmbeddingModel:configuration:),
// then reports RSS at load, first embedding, after 50 embeddings, and 5 s after cleanup() with the manager dropped.
// Also the emb CPU per audio second over disjoint 1.5 s windows, and the Me-vs-say-voice margin on the same embedder.
import CoreML
import FluidAudio
import Foundation
import VoiceDictationLogic

struct MemoryRow {
    var load: Double
    var first: Double
    var fifty: Double
    var cpuPerSec: Double
    var cpuPct: Double
    var meMedian: Double
    var voiceMedian: Double
    var voiceName: String
}

/// The embedder bundles live in the FluidAudio cache. The downloader only fetches wespeaker_v2, so an int8 bundle
/// that is not on disk is reported as n/a rather than built here.
func runMemory(embedder: String, compute: String, seg: String, tile: Int, loaded: [LoadedClip]) throws {
    let key = "embedder=\(embedder) compute=\(compute) seg=\(seg) tile=\(tile)"
    let dir = DiarizerModels.defaultModelsDirectory()
    let bundle = embedder == "int8" ? "wespeaker_int8.mlmodelc" : "wespeaker_v2.mlmodelc"
    let embURL = dir.appendingPathComponent(bundle)
    guard FileManager.default.fileExists(atPath: embURL.path) else {
        print("MEM \(key): n/a, \(bundle) is not in \(dir.path); the downloader has no \(embedder) bundle")
        return
    }
    let segURL = seg == "own" ? dir.appendingPathComponent("pyannote_segmentation.mlmodelc") : embURL
    let cfg = MLModelConfiguration()
    cfg.computeUnits = compute == "all" ? .all : (compute == "ane" ? .cpuAndNeuralEngine : .cpuOnly)

    // Inputs are built before the baseline, so the baseline is the process with the clips already in memory.
    guard let me1 = loaded.first(where: { $0.name == "me1" })?.samples else { throw SpikeError.missingClip("me1") }
    let banks = try pieceBanks(loaded, normalise: true)
    let base = residentMB()
    do {
        let row = try memoryBody(segURL: segURL, embURL: embURL, cfg: cfg, me1: me1, banks: banks, tile: tile)
        Thread.sleep(forTimeInterval: 5)
        let idle = residentMB()
        let margin = row.meMedian - row.voiceMedian
        print("MEM \(key): RSS MB before load \(String(format: "%.0f", base)), after load \(String(format: "%.0f", row.load)), "
            + "first embedding \(String(format: "%.0f", row.first)), after 50 embeddings \(String(format: "%.0f", row.fifty)), "
            + "5 s after cleanup and drop \(String(format: "%.0f", idle)) (delta from before load \(String(format: "%.0f", idle - base)))"
            + " | emb \(String(format: "%.4f", row.cpuPerSec)) CPU s per audio s (\(String(format: "%.1f", row.cpuPct))% of one core)"
            + " | margin \(String(format: "%+.3f", margin)) = Me median \(String(format: "%.3f", row.meMedian)) "
            + "minus \(row.voiceName) median \(String(format: "%.3f", row.voiceMedian))")
    } catch {
        let first = "\(error)".split(separator: "\n").first.map(String.init) ?? "\(error)"
        print("MEM \(key): n/a, \(first)")
    }
}

/// Everything that holds a model lives in this function, so returning drops the manager and its models.
func memoryBody(segURL: URL, embURL: URL, cfg: MLModelConfiguration, me1: [Float], banks: [[[Float]]], tile: Int) throws -> MemoryRow {
    let tileSamples = tile * 16_000
    let models = try DiarizerModels.load(localSegmentationModel: segURL, localEmbeddingModel: embURL, configuration: cfg)
    let diarizer = DiarizerManager()
    diarizer.initialize(models: models)
    let load = residentMB()
    let embed: ([Float]) throws -> [Float] = { try diarizer.extractSpeakerEmbedding(from: $0) }

    let normMe1 = spikeNormalise(me1)
    let wins = disjointWindows(normMe1)
    _ = try embed(spikeTile(wins[0], to: tileSamples))
    let first = residentMB()
    for i in 0..<50 { _ = try embed(spikeTile(wins[i % wins.count], to: tileSamples)) }
    let fifty = residentMB()

    // Margin and CPU pass: the voiceprint, then every Me piece and every say-voice piece, all on this embedder.
    let c0 = cpuSeconds()
    let wall0 = ProcessInfo.processInfo.systemUptime
    var sec = 0.0
    guard let vp = try spikeEmbedding(me1, tileSamples: tileSamples, normalise: true, embed: embed) else {
        throw SpikeError.missingClip("voiceprint embedding")
    }
    func cosines(_ bank: [[Float]]) throws -> [Double] {
        try bank.compactMap { piece -> Double? in
            sec += Double(piece.count) / sampleRate
            guard let e = try spikeEmbedding(piece, tileSamples: tileSamples, normalise: true, embed: embed) else { return nil }
            return SpeakerGate.cosine(e, vp)
        }
    }
    let me = try cosines(banks[0])
    let voices = try [2, 3, 4].map { (name: sayVoices[$0 - 2].voice, cos: try cosines(banks[$0])) }
    let cpu = cpuSeconds() - c0
    let wall = ProcessInfo.processInfo.systemUptime - wall0
    let closest = voices.max { percentile($0.cos, 0.5) < percentile($1.cos, 0.5) }!
    diarizer.cleanup()
    return MemoryRow(load: load, first: first, fifty: fifty,
                     cpuPerSec: sec > 0 ? cpu / sec : 0, cpuPct: wall > 0 ? cpu / wall * 100 : 0,
                     meMedian: percentile(me, 0.5), voiceMedian: percentile(closest.cos, 0.5), voiceName: closest.name)
}
