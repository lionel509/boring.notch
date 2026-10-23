// Speaker-verification spike (#17, U0): the real-mic gate for the dictation speaker gate.
// Records five 8 s clips from the default mic (or replays the saved ones with --replay), embeds
// 1.5 s windows with FluidAudio's WeSpeaker model, and prints similarity numbers only. No audio
// content or audio path is printed; clips stay in the scratch dir.
// Record: cd scripts/speaker-spike && swift run -c release --scratch-path ~/worktrees/boring.notch/.target/speaker-spike
// Replay: the same command with --replay appended (no mic, no prompts).
import AVFoundation
import FluidAudio
import Foundation

let scratch = URL(
    fileURLWithPath: (NSHomeDirectory() as NSString)
        .appendingPathComponent("worktrees/boring.notch/.target/speaker-spike-scratch"),
    isDirectory: true)
let clipSeconds = 8.0
let sampleRate = 16_000.0
let windowSeconds = 1.5
let hopSeconds = 0.75
let tiledSamples = 160_000  // 10 s, the length the embedding model is run at (what embedSpans does)

let promptA = "The quick brown fox jumps over the lazy dog while the notch listens to every word I say."
let promptB = "Please schedule the meeting for Tuesday afternoon and send the notes to the whole team."
let promptC = "Seven green apples, two blue bicycles and one very tired cat were waiting at the station."

let clipPlan: [(label: String, instruction: String)] = [
    ("1 enrol, quiet, Lionel", "Room quiet. Lionel reads: \(promptA)"),
    ("2 quiet, Lionel", "Room quiet. Lionel reads: \(promptB)"),
    ("3 song, Lionel silent", "Play a song on the Mac. Lionel stays silent."),
    ("4 song + Lionel (overlap)", "Same song still playing. Lionel reads: \(promptC)"),
    ("5 other voice", "Play a talking video (not Lionel). Lionel stays silent."),
]

enum SpikeError: Error, CustomStringConvertible {
    case noInput
    case missingClip(Int)
    case conversion(String)

    var description: String {
        switch self {
        case .noInput: return "no usable input device (sample rate 0). Check the mic and the Terminal mic grant."
        case .missingClip(let n): return "clip \(n) is missing. Record without --replay first."
        case .conversion(let why): return "audio conversion failed: \(why)"
        }
    }
}

// MARK: - Recording

final class ClipBuffer: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    var rate: Double = 0
}

func recordClip(seconds: Double) throws -> [Float] {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    guard input.inputFormat(forBus: 0).sampleRate > 0 else { throw SpikeError.noInput }
    let box = ClipBuffer()
    input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        var chunk = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let p = data[c]
            for i in 0..<frames { chunk[i] += p[i] }
        }
        let scale = 1 / Float(channels)
        for i in 0..<frames { chunk[i] *= scale }
        box.lock.lock()
        box.rate = buffer.format.sampleRate
        box.samples.append(contentsOf: chunk)
        box.lock.unlock()
    }
    try engine.start()
    Thread.sleep(forTimeInterval: seconds)
    input.removeTap(onBus: 0)
    engine.stop()

    box.lock.lock()
    let raw = box.samples
    let rate = box.rate
    box.lock.unlock()
    guard rate > 0, !raw.isEmpty else { throw SpikeError.noInput }
    return try resample(raw, from: rate, to: sampleRate)
}

func resample(_ raw: [Float], from rate: Double, to target: Double) throws -> [Float] {
    if rate == target { return raw }
    guard
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
        let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: src, to: dst),
        let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(raw.count)),
        let outBuf = AVAudioPCMBuffer(
            pcmFormat: dst,
            frameCapacity: AVAudioFrameCount(Double(raw.count) * target / rate) + 4096)
    else { throw SpikeError.conversion("setup") }
    inBuf.frameLength = AVAudioFrameCount(raw.count)
    inBuf.floatChannelData![0].update(from: raw, count: raw.count)
    var fed = false
    var err: NSError?
    let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
        if fed {
            outStatus.pointee = .endOfStream
            return nil
        }
        fed = true
        outStatus.pointee = .haveData
        return inBuf
    }
    if status == .error || err != nil { throw SpikeError.conversion(err?.localizedDescription ?? "status") }
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
}

func saveClip(_ samples: [Float], to url: URL) throws {
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))
    else { throw SpikeError.conversion("save buffer") }
    buf.frameLength = AVAudioFrameCount(samples.count)
    buf.floatChannelData![0].update(from: samples, count: samples.count)
    // 16-bit mono WAV, same as the app's own take WAV. The file closes when this scope ends.
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    try file.write(from: buf)
}

func loadClip(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw SpikeError.conversion("load buffer") }
    try file.read(into: buf)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

// MARK: - Math helpers

func rmsDBFS(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return -120 }
    var sum = 0.0
    for v in x { sum += Double(v) * Double(v) }
    let rms = sqrt(sum / Double(x.count))
    return rms > 0 ? 20 * log10(rms) : -120
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<min(a.count, b.count) {
        let x = Double(a[i]), y = Double(b[i])
        dot += x * y
        na += x * x
        nb += y * y
    }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (sqrt(na) * sqrt(nb))
}

func l2Normalised(_ v: [Float]) -> [Float] {
    var n = 0.0
    for x in v { n += Double(x) * Double(x) }
    let norm = Float(sqrt(n))
    guard norm > 0 else { return v }
    return v.map { $0 / norm }
}

func centroid(_ embeddings: [[Float]]) -> [Float] {
    guard let first = embeddings.first else { return [] }
    var sum = [Double](repeating: 0, count: first.count)
    for e in embeddings { for i in 0..<min(e.count, sum.count) { sum[i] += Double(e[i]) } }
    let mean = sum.map { Float($0 / Double(embeddings.count)) }
    return l2Normalised(mean)
}

func windows(_ x: [Float]) -> [[Float]] {
    let w = Int(windowSeconds * sampleRate)
    let h = Int(hopSeconds * sampleRate)
    guard x.count >= w else { return [] }
    var out: [[Float]] = []
    var s = 0
    while s + w <= x.count {
        out.append(Array(x[s..<(s + w)]))
        s += h
    }
    return out
}

func tile(_ x: [Float], to count: Int) -> [Float] {
    guard !x.isEmpty else { return [] }
    var out: [Float] = []
    out.reserveCapacity(count)
    while out.count < count { out.append(contentsOf: x.prefix(count - out.count)) }
    return out
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let s = values.sorted()
    let idx = min(s.count - 1, Int((p * Double(s.count - 1)).rounded(.up)))
    return s[idx]
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

func directorySizeMB(_ url: URL) -> Double {
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total = 0
    for case let f as URL in e {
        total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return Double(total) / 1_048_576
}

func fmt(_ v: Double) -> String { v.isNaN ? "  n/a" : String(format: "%.3f", v) }

// MARK: - Main

let replay = CommandLine.arguments.contains("--replay")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
func clipURL(_ n: Int) -> URL { scratch.appendingPathComponent("clip\(n).wav") }

var clips: [[Float]] = []
if replay {
    for n in 1...clipPlan.count {
        guard FileManager.default.fileExists(atPath: clipURL(n).path) else { throw SpikeError.missingClip(n) }
        clips.append(try loadClip(clipURL(n)))
    }
    print("Replaying \(clips.count) saved clips (no mic).")
} else {
    print("Recording \(clipPlan.count) clips of \(Int(clipSeconds)) s from the default mic.")
    print("For each clip: read the instruction, press Return, then the clip records.\n")
    for (i, step) in clipPlan.enumerated() {
        print("Clip \(i + 1)/\(clipPlan.count) [\(step.label)]")
        print("  \(step.instruction)")
        print("  Press Return to start.", terminator: " ")
        _ = readLine()
        print("  Recording...")
        let samples = try recordClip(seconds: clipSeconds)
        try saveClip(samples, to: clipURL(i + 1))
        print("  Saved. level \(String(format: "%.1f", rmsDBFS(samples))) dBFS\n")
        clips.append(samples)
    }
}

let rssBefore = residentMB()
let modelDir = DiarizerModels.defaultModelsDirectory()
let loadStart = ContinuousClock.now
let models = try await DiarizerModels.downloadIfNeeded()
let diarizer = DiarizerManager()
diarizer.initialize(models: models)
let loadDuration = loadStart.duration(to: .now)
let loadSeconds = Double(loadDuration.components.seconds) + Double(loadDuration.components.attoseconds) / 1e18
let rssAfter = residentMB()

var timingsMs: [Double] = []
func embed(_ window: [Float]) throws -> [Float] {
    let input = tile(window, to: tiledSamples)
    let t0 = ContinuousClock.now
    let e = try diarizer.extractSpeakerEmbedding(from: input)
    let d = t0.duration(to: .now)
    timingsMs.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    return e
}

// Voiceprint: L2-normalised mean of clip 1's window embeddings.
let clip1Windows = windows(clips[0])
let clip1Embeddings = try clip1Windows.map { try embed($0) }
let voiceprint = centroid(clip1Embeddings)

var rows: [(label: String, sims: [Double], level: Double)] = []
for (i, clip) in clips.enumerated() {
    let ws = i == 0 ? clip1Windows : windows(clip)
    let embs = i == 0 ? clip1Embeddings : try ws.map { try embed($0) }
    let sims = embs.map { cosine($0, voiceprint) }
    rows.append((clipPlan[i].label, sims, rmsDBFS(clip)))
}

print("Speaker spike (#17 U0): voiceprint = clip 1, \(clip1Windows.count) windows of \(windowSeconds) s, hop \(hopSeconds) s")
print("clip  condition                       win  min    median max    level dBFS")
for (i, r) in rows.enumerated() {
    let label = r.label.padding(toLength: 27, withPad: " ", startingAt: 0)
    let line = "\(i + 1)     \(label)"
        + " \(String(format: "%3d", r.sims.count))  \(fmt(r.sims.min() ?? .nan))  \(fmt(percentile(r.sims, 0.5)))"
        + "  \(fmt(r.sims.max() ?? .nan))  \(String(format: "%.1f", r.level))"
    print(line)
}

let clip2Min = rows[1].sims.min() ?? .nan
let impostorMax = max(rows[2].sims.max() ?? -1, rows[4].sims.max() ?? -1)
let gap = clip2Min - impostorMax
let medianMs = percentile(timingsMs, 0.5)
let p95Ms = percentile(timingsMs, 0.95)
let rssDelta = rssAfter - rssBefore
let cacheMB = directorySizeMB(modelDir)
let candidate = ((clip2Min + impostorMax) / 2 * 100).rounded() / 100

print("")
print("gate gap  min(clip 2) - max(clip 3, clip 5) = \(fmt(gap))   (rule: >= 0.15)")
print("candidate threshold  midpoint, 2 dp = \(String(format: "%.2f", candidate))")
print("clip 4 (overlap) max = \(fmt(rows[3].sims.max() ?? .nan))   reported, not gated")
print("embed wall ms  median \(String(format: "%.1f", medianMs))  p95 \(String(format: "%.1f", p95Ms))  n=\(timingsMs.count)   (rule: median <= 80)")
print("RSS MB  before load \(String(format: "%.0f", rssBefore))  after load \(String(format: "%.0f", rssAfter))  delta \(String(format: "%.0f", rssDelta))   (rule: <= 150)")
print("model load s \(String(format: "%.1f", loadSeconds))   model cache \(String(format: "%.1f", cacheMB)) MB")

var failed: [String] = []
if !(gap >= 0.15) { failed.append("gap") }
if !(medianMs <= 80) { failed.append("embed ms") }
if !(rssDelta <= 150) { failed.append("RSS") }
print(failed.isEmpty
    ? "rule: GO (lead applies the threshold)"
    : "rule: FLAG, fails \(failed.joined(separator: ", ")). Lead decides window size, wespeaker_int8 or extraction.")
