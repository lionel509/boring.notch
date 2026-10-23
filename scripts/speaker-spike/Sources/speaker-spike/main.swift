// Speaker-verification spike (#17, U0 round 3): the real-mic check for the dictation speaker gate.
// Record: swift run -c release --scratch-path ~/worktrees/boring.notch/.target/speaker-spike -- --record 6,7,8,9,10,11 --stt --segments
//   --record N,N   records those scenes (1-11). Scenes 6-11 are taken twice back to back: VP off, then VP on.
//   --vp A,B,C     capture variants probed for 3 s each, in order (default A,B,C). The first variant that
//                  delivers buffers records the VP-on takes and is named in the table header.
// Replay: the same command with --replay, or with no --record: no mic, no prompts, scores the clips on disk.
// Scenes 1-5 are the VP-off clips from rounds 1-2 and are not re-recorded unless asked.
// Every score is SpeakerGate (VoiceDictationLogic) on audio after an Int16 round trip, live and replay alike,
// so a live run and a --replay of the same files print the same determinism hash.
// Prints numbers only: no transcript text, no audio content, no audio paths. Clips stay in the scratch dir.
import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
import Speech
import VoiceDictationLogic

setvbuf(stdout, nil, _IONBF, 0)  // every probe line shows at once, even when a take dies

let scratch = URL(
    fileURLWithPath: (NSHomeDirectory() as NSString)
        .appendingPathComponent("worktrees/boring.notch/.target/speaker-spike-scratch"),
    isDirectory: true)
let clipSeconds = 8.0
let sampleRate = 16_000.0
let segmentLengths = [2, 3, 5, 8]
let budgetFraction = 0.08  // of one core, during a take (issue #17 CPU budget)
let budgetRSSMB = 80.0

let promptA = "The quick brown fox jumps over the lazy dog while the notch listens to every word I say."
let promptB = "Please schedule the meeting for Tuesday afternoon and send the notes to the whole team."
let promptC = "Seven green apples, two blue bicycles and one very tired cat were waiting at the station."

struct Scene {
    let number: Int
    let label: String
    let instruction: String
    let prompt: String  // what Lionel reads; "" when he stays silent
    let pair: Bool  // recorded twice, VP off then VP on
}

let scenes: [Scene] = [
    Scene(number: 1, label: "enrol, quiet, Lionel", instruction: "Room quiet. Lionel reads: \(promptA)",
          prompt: promptA, pair: false),
    Scene(number: 2, label: "quiet, Lionel", instruction: "Room quiet. Lionel reads: \(promptB)",
          prompt: promptB, pair: false),
    Scene(number: 3, label: "song, Lionel silent", instruction: "Play a song on the Mac. Lionel stays silent.",
          prompt: "", pair: false),
    Scene(number: 4, label: "song + Lionel (overlap)", instruction: "Same song still playing. Lionel reads: \(promptC)",
          prompt: promptC, pair: false),
    Scene(number: 5, label: "other voice", instruction: "Play a talking video (not Lionel). Lionel stays silent.",
          prompt: "", pair: false),
    Scene(number: 6, label: "enrol through VP, Lionel",
          instruction: "Room quiet, phone away. Lionel reads: \(promptA)", prompt: promptA, pair: true),
    Scene(number: 7, label: "lawnmower on phone + Lionel",
          instruction: "Lawnmower or fan video on the phone beside the Mac, at speaking volume. Lionel reads over it: \(promptB)",
          prompt: promptB, pair: true),
    Scene(number: 8, label: "talker on phone + Lionel",
          instruction: "Talking video on the phone beside the Mac (not Lionel). Lionel reads over it: \(promptC)",
          prompt: promptC, pair: true),
    Scene(number: 9, label: "talker on phone, Lionel silent",
          instruction: "The same talking video on the phone. Lionel stays silent.", prompt: "", pair: true),
    Scene(number: 10, label: "song on Mac + Lionel",
          instruction: "Song on the Mac speakers. Lionel reads over it: \(promptA)", prompt: promptA, pair: true),
    Scene(number: 11, label: "song on Mac, Lionel silent",
          instruction: "Song on the Mac speakers. Lionel stays silent.", prompt: "", pair: true),
]

enum Variant: String {
    case off, a = "A", b = "B", c = "C"
}

enum SpikeError: Error, CustomStringConvertible {
    case noInput
    case missingClip(String)
    case conversion(String)
    case badFlag(String)

    var description: String {
        switch self {
        case .noInput: return "no usable input device or no buffers. Check the mic and the Terminal mic grant."
        case .missingClip(let n): return "\(n) is missing. Record it first with --record."
        case .conversion(let why): return "audio conversion failed: \(why)"
        case .badFlag(let why): return why
        }
    }
}

/// Capture numbers for one take, saved beside the clip as clipN[-vp].json. No audio content.
struct CaptureMeta: Codable {
    var variant: String
    var micMode: String
    var inputBefore: String
    var inputAfter: String
    var tapFormat: String
    var buffers: Int
    var channelRMS: [Double]  // dBFS per tap channel, first buffer; channel 0 is recorded
    var levelDBFS: Double
    var captureCPUFraction: Double  // process CPU seconds per wall second during the take
    var wallSeconds: Double
}

struct LoadedClip {
    let scene: Scene
    let vp: Bool
    let name: String
    let samples: [Float]  // 16 kHz, Int16 round trip
    let meta: CaptureMeta?
}

struct ClipResult {
    let clip: LoadedClip
    let byLength: [Int: [Double]]  // segment seconds -> hop-1 s segment scores
    let embedFraction: Double  // CPU per audio second embedding the whole clip (one core if scored live)
    let peakMB: Double
}

struct SttRow {
    let words: Int
    let wer: Double?
    let leak: Int
    let failed: Bool
}

// MARK: - CPU, memory, formatting

func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
        + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

func peakRSSMB() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_maxrss) / 1_048_576  // bytes on macOS
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

func rmsDBFS(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return -120 }
    var sum = 0.0
    for v in x { sum += Double(v) * Double(v) }
    let rms = sqrt(sum / Double(x.count))
    return rms > 0 ? 20 * log10(rms) : -120
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let s = values.sorted()
    let idx = min(s.count - 1, Int((p * Double(s.count - 1)).rounded(.up)))
    return s[idx]
}

func fmt(_ v: Double) -> String { v.isNaN ? "  n/a" : String(format: "%.3f", v) }

func formatText(_ f: AVAudioFormat) -> String { String(format: "%.0f Hz %dch", f.sampleRate, Int(f.channelCount)) }

func tokens(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) }
}

func clipName(_ scene: Int, vp: Bool) -> String { "clip\(scene)\(vp ? "-vp" : "")" }
func clipURL(_ name: String) -> URL { scratch.appendingPathComponent("\(name).wav") }
func metaURL(_ name: String) -> URL { scratch.appendingPathComponent("\(name).json") }

// MARK: - Capture

final class TapBox: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    var rate: Double = 0
    var buffers = 0
    var channelRMS: [Double] = []
}

/// Result of one take. Capture never throws: a failed take carries its reason and the caller decides.
struct TakeResult {
    let samples: [Float]  // 16 kHz mono
    let meta: CaptureMeta
    let failure: String?
}

func describe(_ input: AVAudioInputNode) -> String {
    "in \(formatText(input.inputFormat(forBus: 0))) out \(formatText(input.outputFormat(forBus: 0)))"
}

func micModeName() -> String {
    guard #available(macOS 26.0, *) else { return "n/a" }
    switch AVCaptureDevice.activeMicrophoneMode {
    case .standard: return "standard"
    case .voiceIsolation: return "voiceIsolation"
    case .wideSpectrum: return "wideSpectrum"
    @unknown default: return "other"
    }
}

/// Builds the take from what the tap collected. Called on every path, success or failure.
func takeResult(_ box: TapBox, variant: String, before: String, after: String, tap: String,
                wall: Double, cpu: Double, failure: String?) -> TakeResult {
    box.lock.lock()
    let raw = box.samples
    let rate = box.rate
    let buffers = box.buffers
    let rms = box.channelRMS
    box.lock.unlock()
    var failure = failure
    var samples: [Float] = []
    if !raw.isEmpty && rate > 0 {
        do { samples = try resample(raw, from: rate, to: sampleRate) } catch { failure = failure ?? "resample: \(error)" }
    }
    if failure == nil && buffers == 0 { failure = "no buffers delivered" }
    let meta = CaptureMeta(
        variant: variant, micMode: micModeName(), inputBefore: before, inputAfter: after,
        tapFormat: tap, buffers: buffers, channelRMS: rms, levelDBFS: rmsDBFS(samples),
        captureCPUFraction: wall > 0 ? cpu / wall : 0, wallSeconds: wall)
    return TakeResult(samples: samples, meta: meta, failure: failure)
}

/// One take on a fresh engine. off: plain capture, tap format read after prepare. A: VP on. B: A plus the VPIO
/// render side (mixer to output, volume 0). C: B, with Voice Isolation picked by Lionel. Channel 0 is recorded
/// (MicChannelPick.monoSource rule); per-channel dBFS of the first buffer is recorded.
func capture(seconds: Double, variant: Variant) -> TakeResult {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let box = TapBox()
    let before = describe(input)
    guard input.inputFormat(forBus: 0).sampleRate > 0 else {
        return takeResult(box, variant: variant.rawValue, before: before, after: before, tap: "none",
                          wall: 0, cpu: 0, failure: "input sampleRate 0 (no input device or no mic grant)")
    }
    if variant != .off {
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            return takeResult(box, variant: variant.rawValue, before: before, after: describe(input), tap: "none",
                              wall: 0, cpu: 0, failure: "setVoiceProcessingEnabled(true): \(error)")
        }
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .min)
    }
    let after = describe(input)
    if variant == .b || variant == .c {
        guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            return takeResult(box, variant: variant.rawValue, before: before, after: after, tap: "none",
                              wall: 0, cpu: 0, failure: "output node 0 Hz: variant \(variant.rawValue) needs an output device")
        }
        engine.connect(input, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0
    }
    engine.prepare()
    let tapFormat = input.outputFormat(forBus: 0)
    guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
        return takeResult(box, variant: variant.rawValue, before: before, after: after,
                          tap: formatText(tapFormat), wall: 0, cpu: 0,
                          failure: "tap format \(formatText(tapFormat)) not usable")
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        box.lock.lock()
        if box.buffers == 0 {
            box.channelRMS = (0..<channels).map { c in
                rmsDBFS(Array(UnsafeBufferPointer(start: data[c], count: frames)))
            }
        }
        box.buffers += 1
        box.rate = buffer.format.sampleRate
        box.samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
        box.lock.unlock()
    }
    let cpu0 = cpuSeconds()
    let wall0 = Date()
    var failure: String? = nil
    do {
        try engine.start()
        Thread.sleep(forTimeInterval: seconds)
    } catch {
        failure = "engine.start: \(error)"
    }
    input.removeTap(onBus: 0)
    engine.stop()
    let wall = Date().timeIntervalSince(wall0)
    let cpu = cpuSeconds() - cpu0
    return takeResult(box, variant: variant.rawValue, before: before, after: after,
                      tap: formatText(tapFormat), wall: wall, cpu: cpu, failure: failure)
}

/// The round-1 capture path (format nil, channels averaged), used for the VP-off half of every scene so the
/// VP-off clips are made the way clips 1-5 were. Never throws.
func captureRound1(seconds: Double) -> TakeResult {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let box = TapBox()
    let before = describe(input)
    guard input.inputFormat(forBus: 0).sampleRate > 0 else {
        return takeResult(box, variant: "round1", before: before, after: before, tap: "nil",
                          wall: 0, cpu: 0, failure: "input sampleRate 0 (no input device or no mic grant)")
    }
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
        if box.buffers == 0 {
            box.channelRMS = (0..<channels).map { c in
                rmsDBFS(Array(UnsafeBufferPointer(start: data[c], count: frames)))
            }
        }
        box.buffers += 1
        box.rate = buffer.format.sampleRate
        box.samples.append(contentsOf: chunk)
        box.lock.unlock()
    }
    let cpu0 = cpuSeconds()
    let wall0 = Date()
    var failure: String? = nil
    do {
        try engine.start()
        Thread.sleep(forTimeInterval: seconds)
    } catch {
        failure = "engine.start: \(error)"
    }
    input.removeTap(onBus: 0)
    engine.stop()
    let wall = Date().timeIntervalSince(wall0)
    let cpu = cpuSeconds() - cpu0
    return takeResult(box, variant: "round1", before: before, after: describe(input), tap: "nil, channels averaged",
                      wall: wall, cpu: cpu, failure: failure)
}

func printTake(_ label: String, _ take: TakeResult) {
    let m = take.meta
    let chans = m.channelRMS.map { String(format: "%.1f", $0) }.joined(separator: " ")
    print("  \(label)  \(m.inputBefore) | after VP \(m.inputAfter) | tap \(m.tapFormat) | buffers \(m.buffers)"
        + " | ch dBFS \(chans) | level \(String(format: "%.1f", m.levelDBFS)) | mic \(m.micMode)")
    if let why = take.failure { print("  \(label)  FAILED: \(why)") }
}

/// Probes the capture variants for 3 s each, in order, each on a fresh engine. Returns the first that delivers
/// buffers. Every variant's result is printed, failures included.
func probeCaptureVariants(_ variants: [Variant]) -> (variant: Variant, meta: CaptureMeta)? {
    print("Capture probe, 3 s per variant, first that delivers buffers is used: \(variants.map(\.rawValue).joined(separator: ","))")
    var reasons: [String] = []
    for v in variants {
        if v == .c {
            print("Variant C: the system mic panel opens. Pick Voice Isolation in Control Center, then press Return.")
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
            _ = readLine()
        }
        let take = capture(seconds: 3, variant: v)
        printTake(v.rawValue, take)
        if take.failure == nil && take.meta.buffers > 0 { return (v, take.meta) }
        reasons.append("\(v.rawValue): \(take.failure ?? "no buffers")")
    }
    print("VP: none delivered. " + reasons.joined(separator: "; "))
    return nil
}

/// Records one take and saves it. Returns false when the take produced no audio. Never throws.
func recordTake(_ scene: Scene, vp: Bool, variant: Variant?) -> Bool {
    let name = clipName(scene.number, vp: vp)
    let label = vp ? "VP on, variant \(variant?.rawValue ?? "?")" : "VP off, round-1 path"
    print("Take \(name) [\(scene.label)] \(label)")
    print("  \(scene.instruction)")
    print("  Press Return to start.", terminator: " ")
    _ = readLine()
    print("  Recording...")
    let take = vp ? capture(seconds: clipSeconds, variant: variant ?? .a) : captureRound1(seconds: clipSeconds)
    guard !take.samples.isEmpty else {
        print("  FAILED: \(take.failure ?? "no audio")\n")
        return false
    }
    do {
        try saveClip(take.samples, to: clipURL(name))
        try JSONEncoder().encode(take.meta).write(to: metaURL(name))
    } catch {
        print("  FAILED to save: \(error)\n")
        return false
    }
    print("  Saved. level \(String(format: "%.1f", take.meta.levelDBFS)) dBFS, capture CPU "
        + "\(String(format: "%.1f", take.meta.captureCPUFraction * 100))% of one core\n")
    return true
}

// MARK: - Files

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

// MARK: - STT (lifted from scripts/stt-bench/main.swift)

@available(macOS 26.0, *)
func appleTranscribe(_ url: URL) async throws -> String {
    let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let audio = try AVAudioFile(forReading: url)
    let collector = Task { () -> String in
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }
    _ = try await analyzer.analyzeSequence(from: audio)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return try await collector.value
}

/// Leak = transcript words not matched by the prompt (multiset). Only the counts leave this function.
@available(macOS 26.0, *)
func sttFile(_ url: URL, prompt: String) async -> SttRow {
    do {
        let text = try await appleTranscribe(url)
        let hyp = tokens(text)
        var left: [String: Int] = [:]
        for w in tokens(prompt) { left[w, default: 0] += 1 }
        var leak = 0
        for w in hyp {
            if let n = left[w], n > 0 { left[w] = n - 1 } else { leak += 1 }
        }
        let wer: Double? = prompt.isEmpty ? nil : WordErrorRate.wer(reference: prompt, hypothesis: text)
        return SttRow(words: hyp.count, wer: wer, leak: leak, failed: false)
    } catch {
        return SttRow(words: 0, wer: nil, leak: 0, failed: true)
    }
}

@available(macOS 26.0, *)
func sttRow(_ c: LoadedClip) async -> SttRow {
    await sttFile(clipURL(c.name), prompt: c.scene.prompt)
}

// MARK: - Arguments

let args = CommandLine.arguments
func flagValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let replay = args.contains("--replay")
let wantSegments = args.contains("--segments")
let wantSTT = args.contains("--stt")
let mixMode = args.contains("--mix")

var recordList: [Int]? = nil
if let v = flagValue("--record") {
    let nums = v.split(separator: ",").compactMap { Int($0) }
    guard !nums.isEmpty, nums.allSatisfy({ (1...scenes.count).contains($0) }) else {
        throw SpikeError.badFlag("bad --record (comma list of scene numbers 1-11)")
    }
    recordList = nums
}
if replay && recordList != nil { throw SpikeError.badFlag("--replay and --record cannot be combined") }
var variantList: [Variant] = [.a, .b, .c]
if let v = flagValue("--vp") {
    let parsed = v.split(separator: ",").compactMap { Variant(rawValue: String($0).uppercased()) }
    guard !parsed.isEmpty, !parsed.contains(.off) else { throw SpikeError.badFlag("bad --vp (comma list of A, B, C)") }
    variantList = parsed
}

// MARK: - Record

try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

if let list = recordList {
    print("Recording scenes \(list.map(String.init).joined(separator: ",")) from the default mic. "
        + "Read each instruction, press Return, then the take records 8 s.\n")
    var chosen: (variant: Variant, meta: CaptureMeta)? = nil
    if list.contains(where: { scenes[$0 - 1].pair }) {
        chosen = probeCaptureVariants(variantList)
    }
    var vpOffFailed = false
    for n in list {
        let scene = scenes[n - 1]
        if !recordTake(scene, vp: false, variant: nil) { vpOffFailed = true }
        if scene.pair {
            if let c = chosen {
                _ = recordTake(scene, vp: true, variant: c.variant)
            } else {
                print("  VP none delivered: the VP-on take of scene \(n) is skipped.\n")
            }
        }
    }
    if vpOffFailed {
        fputs("A VP-off take failed. Check the mic and the Terminal mic grant.\n", stderr)
        exit(1)
    }
}

// MARK: - Load (live and replay take the same path: file, then Int16 round trip)

var loaded: [LoadedClip] = []
for scene in scenes {
    for vp in (scene.pair ? [false, true] : [false]) {
        let name = clipName(scene.number, vp: vp)
        guard FileManager.default.fileExists(atPath: clipURL(name).path) else { continue }
        let raw = try loadClip(clipURL(name))
        let meta = try? JSONDecoder().decode(CaptureMeta.self, from: Data(contentsOf: metaURL(name)))
        loaded.append(LoadedClip(scene: scene, vp: vp, name: name,
                                 samples: SpeakerGate.int16RoundTrip(raw), meta: meta))
    }
}
guard loaded.contains(where: { $0.name == "clip1" }) else { throw SpikeError.missingClip("clip 1") }
print("Scoring \(loaded.count) clips (no mic).\n")

// MARK: - Model

let rssBefore = residentMB()
let modelDir = DiarizerModels.defaultModelsDirectory()
let loadStart = ContinuousClock.now
let models = try await DiarizerModels.downloadIfNeeded()
let diarizer = DiarizerManager()
diarizer.initialize(models: models)
let loadDuration = loadStart.duration(to: .now)
let loadSeconds = Double(loadDuration.components.seconds) + Double(loadDuration.components.attoseconds) / 1e18
let rssAfterLoad = residentMB()

var timingsMs: [Double] = []
func embedWindow(_ tiled: [Float]) throws -> [Float] {
    let t0 = ContinuousClock.now
    let e = try diarizer.extractSpeakerEmbedding(from: tiled)
    let d = t0.duration(to: .now)
    timingsMs.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    return e
}

/// Hop-1 s segments of `seconds` length, each scored through SpeakerGate.score.
func scoreSegments(_ x: [Float], voiceprint: [Float], seconds: Int) throws -> [Double] {
    let len = min(seconds * Int(sampleRate), x.count)
    guard len > 0 else { return [] }
    let hop = Int(sampleRate)
    var out: [Double] = []
    var s = 0
    while s + len <= x.count {
        if let v = try SpeakerGate.score(segment: Array(x[s..<(s + len)]), voiceprint: voiceprint, embed: embedWindow) {
            out.append(v)
        }
        s += hop
    }
    return out
}

// MARK: - Mix (offline, no mic). Clip 2 is the speech, clip 1 the voiceprint. Interferers: song (clip 3), talker
// (clip 5), three say voices, and generated brown, pink and AM brown (mower) noise. Each mix is scored with the
// Voice Isolation AU off and on, after an Int16 round trip, through the same SpeakerGate segment path.

enum MixError: Error, CustomStringConvertible {
    case au(String)
    case say(String)

    var description: String {
        switch self {
        case .au(let why): return "isolation AU: \(why)"
        case .say(let why): return "say: \(why)"
        }
    }
}

struct Lcg {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / 9_007_199_254_740_992.0 * 2 - 1  // [-1, 1)
    }
}

func unitRMS(_ x: [Float]) -> [Float] {
    let power = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))
    guard power > 0 else { return x }
    let r = Float(sqrt(power))
    return x.map { $0 / r }
}

func brownNoise(_ n: Int, seed: UInt64) -> [Float] {
    var rng = Lcg(state: seed)
    var b = 0.0
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        b = (b + 0.02 * rng.next()) / 1.02
        out[i] = Float(b)
    }
    return unitRMS(out)
}

func pinkNoise(_ n: Int, seed: UInt64) -> [Float] {
    var rng = Lcg(state: seed)
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let w = rng.next()
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        out[i] = Float(b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362)
        b6 = w * 0.115926
    }
    return unitRMS(out)
}

/// Engine-like: brown noise amplitude-modulated at 30 Hz.
func mowerNoise(_ n: Int, seed: UInt64) -> [Float] {
    let brown = brownNoise(n, seed: seed)
    let am = (0..<n).map { i in
        brown[i] * Float(0.5 + 0.5 * sin(2 * Double.pi * 30 * Double(i) / sampleRate))
    }
    return unitRMS(am)
}

/// Repeats or truncates x to exactly n samples.
func fit(_ x: [Float], to n: Int) -> [Float] {
    guard !x.isEmpty else { return [Float](repeating: 0, count: n) }
    var out: [Float] = []
    out.reserveCapacity(n)
    while out.count < n { out.append(contentsOf: x.prefix(n - out.count)) }
    return out
}

/// 20 ms frames within 30 dB of the loudest frame: the voiced part of the clean speech.
func voicedRanges(_ x: [Float]) -> [Range<Int>] {
    let f = Int(0.02 * sampleRate)
    var frames: [(range: Range<Int>, level: Double)] = []
    var s = 0
    while s + f <= x.count {
        frames.append((s..<(s + f), rmsDBFS(Array(x[s..<(s + f)]))))
        s += f
    }
    guard let peak = frames.map(\.level).max() else { return [] }
    return frames.filter { $0.level >= peak - 30 }.map(\.range)
}

func meanSquare(_ x: [Float], _ ranges: [Range<Int>]) -> Double {
    var sum = 0.0
    var count = 0
    for r in ranges {
        for i in r { sum += Double(x[i]) * Double(x[i]) }
        count += r.count
    }
    return count > 0 ? sum / Double(count) : 0
}

/// Gain for the interferer so that its power over the clean voiced part sits at snrDB.
func snrGain(clean: [Float], interferer: [Float], snrDB: Double) -> Float {
    let voiced = voicedRanges(clean)
    let cp = meanSquare(clean, voiced)
    let ip = meanSquare(interferer, voiced)
    guard ip > 0 else { return 0 }
    return Float(sqrt(cp / ip) / pow(10, snrDB / 20))
}

func sayClip(voice: String, text: String, to url: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", url.path, "--data-format=BEF32@16000", text]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw MixError.say("\(voice) exit \(p.terminationStatus)") }
}

/// Voice Isolation AU (AUSoundIsolation, 'vois', macOS 13+) in AVAudioEngine manual rendering at 48 kHz.
/// The 16 kHz input goes up to 48 kHz and the output comes back to 16 kHz, with the AU's own latency removed.
func isolateOffline(_ x16: [Float]) throws -> [Float] {
    let x48 = try resample(x16, from: sampleRate, to: 48_000)
    guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
          let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x48.count)),
          let block = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)
    else { throw MixError.au("buffers") }
    inBuf.frameLength = AVAudioFrameCount(x48.count)
    inBuf.floatChannelData![0].update(from: x48, count: x48.count)

    let desc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let unit = AVAudioUnitEffect(audioComponentDescription: desc)
    do {
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
    } catch {
        throw MixError.au("manual rendering: \(error)")
    }
    engine.attach(player)
    engine.attach(unit)
    engine.connect(player, to: unit, format: fmt)
    engine.connect(unit, to: engine.mainMixerNode, format: fmt)
    engine.prepare()
    do {
        try engine.start()
    } catch {
        throw MixError.au("engine.start: \(error)")
    }
    let latency = Int(unit.auAudioUnit.latency * 48_000)
    let total = x48.count + latency + 4_800  // tail so the unit flushes
    player.scheduleBuffer(inBuf, completionHandler: nil)
    player.play()
    var out: [Float] = []
    out.reserveCapacity(total)
    while out.count < total {
        let want = AVAudioFrameCount(min(4096, total - out.count))
        let status: AVAudioEngineManualRenderingStatus
        do {
            status = try engine.renderOffline(want, to: block)
        } catch {
            throw MixError.au("renderOffline: \(error)")
        }
        guard status == .success else { throw MixError.au("render status \(status.rawValue)") }
        out.append(contentsOf: UnsafeBufferPointer(start: block.floatChannelData![0], count: Int(block.frameLength)))
    }
    player.stop()
    engine.stop()
    let body = Array(out.dropFirst(latency).prefix(x48.count))
    return try resample(body, from: 48_000, to: sampleRate)
}

func resampleRoundTrip(_ x: [Float]) throws -> [Float] {
    try resample(try resample(x, from: sampleRate, to: 48_000), from: 48_000, to: sampleRate)
}

struct MixResult {
    let name: String  // source: clean, song, talker, say-*, brown, pink, mower
    let label: String  // SNR in dB, "only" (interferer alone) or "clean"
    let iso: Bool
    let min: Double
    let med: Double
    let max: Double
    let stt: SttRow?
    let isoCPU: Double?
    let embCPU: Double
}

var auFailure: String? = nil

/// One scored row. x is already on the path it is scored on (OFF or ON), Int16 round tripped.
func mixRow(name: String, label: String, iso: Bool, x: [Float], isoCPU: Double?, voiceprint: [Float],
            prompt: String, wantSTT: Bool) async throws -> MixResult {
    let audioSec = Double(x.count) / sampleRate
    let c0 = cpuSeconds()
    let scores = try scoreSegments(x, voiceprint: voiceprint, seconds: 3)
    let embCPU = audioSec > 0 ? (cpuSeconds() - c0) / audioSec : 0
    var stt: SttRow? = nil
    if wantSTT, #available(macOS 26.0, *) {
        let url = scratch.appendingPathComponent("row-\(name)-\(label)-\(iso ? "on" : "off").wav")
        try saveClip(x, to: url)
        stt = await sttFile(url, prompt: prompt)
    }
    return MixResult(name: name, label: label, iso: iso, min: scores.min() ?? .nan,
                     med: percentile(scores, 0.5), max: scores.max() ?? .nan, stt: stt,
                     isoCPU: isoCPU, embCPU: embCPU)
}

func printMixRow(_ r: MixResult) {
    let key = "\(r.name) \(r.label)".padding(toLength: 22, withPad: " ", startingAt: 0)
    var line = "\(key) \(r.iso ? "on " : "off") \(lengthCell(r.min))  \(lengthCell(r.med))  \(lengthCell(r.max))"
    if let s = r.stt {
        let wer = s.failed ? "fail" : (s.wer.map { String(format: "%.3f", $0) } ?? "  n/a")
        line += "  \(String(format: "%4d", s.leak))  \(wer.padding(toLength: 5, withPad: " ", startingAt: 0))"
            + "  \(String(format: "%5d", s.words))"
    }
    let iso = r.isoCPU.map { String(format: "%6.3f", $0) } ?? "     -"
    line += "   \(iso)   \(String(format: "%6.3f", r.embCPU))"
    print(line)
}

/// Scores the source off and on the isolation AU. If the AU cannot render, its rows are dropped and the
/// reason is kept for the table (isolation OFF rows only).
func mixSource(name: String, label: String, x: [Float], voiceprint: [Float], prompt: String,
               wantSTT: Bool) async throws -> [MixResult] {
    var rows: [MixResult] = []
    let off = SpeakerGate.int16RoundTrip(try resampleRoundTrip(x))
    rows.append(try await mixRow(name: name, label: label, iso: false, x: off, isoCPU: nil,
                                 voiceprint: voiceprint, prompt: prompt, wantSTT: wantSTT))
    if auFailure == nil {
        do {
            let c0 = cpuSeconds()
            let on = SpeakerGate.int16RoundTrip(try isolateOffline(x))
            let cpu = cpuSeconds() - c0
            let audioSec = Double(x.count) / sampleRate
            rows.append(try await mixRow(name: name, label: label, iso: true, x: on,
                                         isoCPU: audioSec > 0 ? cpu / audioSec : 0,
                                         voiceprint: voiceprint, prompt: prompt, wantSTT: wantSTT))
        } catch {
            auFailure = "\(error)"
            print("isolation AU not available offline: \(error). Isolation OFF rows only from here.")
        }
    }
    for r in rows { printMixRow(r) }
    return rows
}

@available(macOS 26.0, *)
func runMix(wantSTT: Bool) async throws {
    guard let c1 = loaded.first(where: { $0.name == "clip1" }),
          let c2 = loaded.first(where: { $0.name == "clip2" }),
          let c3 = loaded.first(where: { $0.name == "clip3" }),
          let c5 = loaded.first(where: { $0.name == "clip5" })
    else { throw SpikeError.missingClip("clip 1, 2, 3 and 5") }
    guard let voiceprint = try SpeakerGate.segmentEmbedding(c1.samples, embed: embedWindow) else {
        throw SpikeError.missingClip("clip 1 embedding")
    }
    let n = c2.samples.count
    let prompt = c2.scene.prompt
    print("Mix (offline, no mic): clip 2 speech, clip 1 voiceprint, 3 s segments, hop 1 s.")
    print("row                    iso  min     median  max      leak    WER    words   iso s/s  emb s/s")

    var sayLines: [(String, String, String)] = [
        ("say-samantha", "Samantha", "The committee approved the new budget after a long discussion about the harbour bridge."),
        ("say-daniel", "Daniel", "Remember to water the plants on the balcony before the weekend, because the forecast says it will be hot."),
        ("say-karen", "Karen", "Our train was delayed twice, so we walked the last few miles along the river to the old market."),
    ]
    var interferers: [(String, [Float])] = [
        ("song", fit(c3.samples, to: n)),
        ("talker", fit(c5.samples, to: n)),
    ]
    for (name, voice, text) in sayLines {
        let url = scratch.appendingPathComponent("\(name).aiff")
        try sayClip(voice: voice, text: text, to: url)
        interferers.append((name, fit(SpeakerGate.int16RoundTrip(try loadClip(url)), to: n)))
    }
    interferers.append(("brown", fit(brownNoise(n, seed: 11), to: n)))
    interferers.append(("pink", fit(pinkNoise(n, seed: 23), to: n)))
    interferers.append(("mower", fit(mowerNoise(n, seed: 37), to: n)))
    sayLines = []

    var results: [MixResult] = []
    results += try await mixSource(name: "clean", label: "clean", x: c2.samples, voiceprint: voiceprint,
                                   prompt: prompt, wantSTT: wantSTT)
    for (name, x) in interferers {
        for snr in [10.0, 5.0, 0.0, -5.0] {
            let g = snrGain(clean: c2.samples, interferer: x, snrDB: snr)
            var mix = [Float](repeating: 0, count: n)
            for i in 0..<n { mix[i] = c2.samples[i] + g * x[i] }
            let label = snr > 0 ? "+\(Int(snr))" : "\(Int(snr))"
            let url = scratch.appendingPathComponent("mix-\(name)-\(label).wav")
            try saveClip(mix, to: url)
            let stored = SpeakerGate.int16RoundTrip(try loadClip(url))
            results += try await mixSource(name: name, label: label, x: stored, voiceprint: voiceprint,
                                           prompt: prompt, wantSTT: wantSTT)
        }
        // Interferer alone at the 0 dB gain: the layer 2 negatives (no Lionel).
        let g0 = snrGain(clean: c2.samples, interferer: x, snrDB: 0)
        let only = x.map { $0 * g0 }
        let url = scratch.appendingPathComponent("only-\(name).wav")
        try saveClip(only, to: url)
        let stored = SpeakerGate.int16RoundTrip(try loadClip(url))
        results += try await mixSource(name: name, label: "only", x: stored, voiceprint: voiceprint,
                                       prompt: "", wantSTT: wantSTT)
    }

    // Gate summary (the lead applies it; these lines carry the numbers).
    print("\nLayer 1 (offline isolation ON), 0 dB, gate: 3 s median >= 0.35 and leak <= 3 with WER <= 2x clean")
    let cleanOn = results.first { $0.name == "clean" && $0.iso }
    let cleanWER = cleanOn?.stt?.wer
    for name in interferers.map(\.0) {
        guard let r = results.first(where: { $0.name == name && $0.label == "0" && $0.iso }) else {
            print("  \(name): isolation ON not run (AU unavailable)")
            continue
        }
        let medOK = r.med >= 0.35
        var sttText = "stt not run"
        if let s = r.stt, let w = s.wer, let w0 = cleanWER {
            sttText = "leak \(s.leak), WER \(String(format: "%.3f", w)) vs clean \(String(format: "%.3f", w0)) "
                + (s.leak <= 3 && w <= 2 * w0 ? "PASS" : "FAIL")
        }
        print("  \(name): median \(fmt(r.med)) \(medOK ? "PASS" : "FAIL"), \(sttText)")
    }
    print("\nLayer 2 (negatives: interferer alone, 3 s), gate: min(clean clip 2) - max(interferer alone) >= 0.20")
    for iso in [true, false] {
        let his = results.first { $0.name == "clean" && $0.iso == iso }
        let others = results.filter { $0.label == "only" && $0.iso == iso }
        let hisMin = his?.min ?? .nan
        let othersMax = others.map(\.max).max() ?? .nan
        let gap = hisMin - othersMax
        let threshold = ((hisMin + othersMax) / 2 * 100).rounded() / 100
        print("  isolation \(iso ? "ON " : "OFF"): his min \(fmt(hisMin)), negatives max \(fmt(othersMax)), "
            + "gap \(fmt(gap)) \(gap >= 0.20 ? "PASS" : "FAIL"), candidate threshold \(String(format: "%.2f", threshold))")
    }
    print("\nClip 2 in mix, 0 dB, isolation ON, 3 s median:")
    for (label, names) in [("song", ["song"]), ("talker", ["talker"]), ("noise", ["brown", "pink", "mower"])] {
        let parts = names.map { nm -> String in
            let v = results.first { $0.name == nm && $0.label == "0" && $0.iso }
            return "\(nm) \(v.map { fmt($0.med) } ?? "n/a")"
        }
        print("  \(label): \(parts.joined(separator: ", "))")
    }
    print("\nisolation AU: \(auFailure.map { "unavailable offline: \($0)" } ?? "ran for every ON row")")
}

if mixMode {
    if #available(macOS 26.0, *) {
        try await runMix(wantSTT: wantSTT)
    } else {
        print("--mix runs on macOS 26 (SpeechAnalyzer for --stt). Skipped.")
    }
    exit(0)
}

// Embedding each clip once: the cost is measured here (the budget), and the voiceprints come from this map.
var segEmb: [String: [Float]] = [:]
var embedFraction: [String: Double] = [:]
for c in loaded {
    let c0 = cpuSeconds()
    let e = try SpeakerGate.segmentEmbedding(c.samples, embed: embedWindow)
    let cpu = cpuSeconds() - c0
    let audioSec = Double(c.samples.count) / sampleRate
    embedFraction[c.name] = audioSec > 0 ? cpu / audioSec : 0
    if let e { segEmb[c.name] = e }
}
// VP-off clips are scored against clip 1; VP-on clips against clip 6-vp (the enrolment taken through VP).
let vpOffPrint = segEmb["clip1"]
let vpOnPrint = segEmb["clip6-vp"]

var results: [ClipResult] = []
for c in loaded {
    guard let vector = c.vp ? vpOnPrint : vpOffPrint else { continue }
    var byLength: [Int: [Double]] = [:]
    for seconds in segmentLengths {
        byLength[seconds] = try scoreSegments(c.samples, voiceprint: vector, seconds: seconds)
    }
    results.append(ClipResult(clip: c, byLength: byLength, embedFraction: embedFraction[c.name] ?? 0,
                              peakMB: peakRSSMB()))
}

// Determinism: SHA-256 over the 3 s scores of every clip, as big-endian Double bit patterns.
var scoreBytes: [UInt8] = []
for r in results {
    for v in r.byLength[3] ?? [] {
        withUnsafeBytes(of: v.bitPattern.bigEndian) { scoreBytes.append(contentsOf: $0) }
    }
}
let determinismHash = SHA256.hash(data: Data(scoreBytes)).map { String(format: "%02x", $0) }.joined()
let determinismCount = scoreBytes.count / 8

var sttRows: [String: SttRow] = [:]
if wantSTT {
    if #available(macOS 26.0, *) {
        for c in loaded { sttRows[c.name] = await sttRow(c) }
    } else {
        print("--stt needs macOS 26 (SpeechAnalyzer). Skipped.")
    }
}

// MARK: - Table

func lengthCell(_ v: Double) -> String { v.isNaN ? "   n/a" : String(format: "%6.3f", v) }

if let m = loaded.first(where: { $0.vp && $0.meta != nil })?.meta {
    let chans = m.channelRMS.map { String(format: "%.1f", $0) }.joined(separator: " ")
    print("capture: VP variant \(m.variant), mic mode \(m.micMode), tap \(m.tapFormat), ch dBFS \(chans), channel 0 recorded")
} else {
    print("capture: no VP-on take with capture numbers on disk")
}
print("determinism  SHA-256 of \(determinismCount) 3 s scores = \(determinismHash.prefix(16))  (live and replay must match)")
print("")
var header = "clip  condition                    vs      n    min  median    max   dBFS   cap%   emb%  peakMB"
if wantSTT { header += "  words    WER  leak" }
print(header)
for r in results {
    let s3 = r.byLength[3] ?? []
    let label = r.clip.scene.label.padding(toLength: 28, withPad: " ", startingAt: 0)
    let name = r.clip.name.padding(toLength: 6, withPad: " ", startingAt: 0)
    let vs = (r.clip.vp ? "6-vp" : "1").padding(toLength: 6, withPad: " ", startingAt: 0)
    let cap = r.clip.meta.map { String(format: "%5.1f", $0.captureCPUFraction * 100) } ?? "  n/a"
    var line = "\(name)  \(label) \(vs)\(String(format: "%4d", s3.count))"
        + " \(lengthCell(s3.min() ?? .nan))  \(lengthCell(percentile(s3, 0.5)))  \(lengthCell(s3.max() ?? .nan))"
        + "  \(String(format: "%6.1f", rmsDBFS(r.clip.samples)))"
        + "  \(cap)  \(String(format: "%5.1f", r.embedFraction * 100))  \(String(format: "%6.0f", r.peakMB))"
    if wantSTT {
        if let s = sttRows[r.clip.name] {
            let werText = s.failed ? "fail" : (s.wer.map { String(format: "%.3f", $0) } ?? "  n/a")
            line += "  \(String(format: "%5d", s.words))  \(werText.padding(toLength: 5, withPad: " ", startingAt: 0))"
                + "  \(String(format: "%4d", s.leak))"
        } else {
            line += "  stt n/a"
        }
    }
    print(line)
}

if wantSegments {
    print("\nsegments (hop 1 s): length, n, min, median, max")
    for r in results {
        for seconds in segmentLengths {
            let v = r.byLength[seconds] ?? []
            print("\(r.clip.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(String(format: "%d", seconds)) s"
                + "  n \(String(format: "%3d", v.count))  \(lengthCell(v.min() ?? .nan))"
                + "  \(lengthCell(percentile(v, 0.5)))  \(lengthCell(v.max() ?? .nan))")
        }
    }
}

// MARK: - Gates (the lead applies them; these lines carry the numbers)

func row(_ name: String) -> ClipResult? { results.first { $0.clip.name == name } }

print("\nLayer 1 (VP on), gate: 3 s median >= 0.35 and leak <= 3 with WER <= 2x clip 6-vp")
let ref6WER = sttRows["clip6-vp"]?.wer
var l1Fail: [String] = []
var l1Pending: [String] = []
for name in ["clip7-vp", "clip8-vp", "clip10-vp"] {
    guard let r = row(name) else {
        print("  \(name): not recorded")
        l1Fail.append(name)
        continue
    }
    let med = percentile(r.byLength[3] ?? [], 0.5)
    let medOK = med >= 0.35
    var sttText = "stt not run"
    var sttOK: Bool? = nil
    if let s = sttRows[name] {
        if s.failed {
            sttText = "stt failed"
            sttOK = false
        } else {
            let werText = s.wer.map { String(format: "%.3f", $0) } ?? "n/a"
            sttText = "leak \(s.leak), WER \(werText) vs 6-vp \(ref6WER.map { String(format: "%.3f", $0) } ?? "n/a")"
            if let w = s.wer, let w6 = ref6WER { sttOK = s.leak <= 3 && w <= 2 * w6 }
        }
    }
    if !medOK || sttOK == false { l1Fail.append(name) }
    if sttOK == nil { l1Pending.append(name) }
    print("  \(name): median \(fmt(med)) \(medOK ? "PASS" : "FAIL"), \(sttText) "
        + "\(sttOK.map { $0 ? "PASS" : "FAIL" } ?? "pending")")
}
for name in ["clip9-vp", "clip11-vp"] {
    guard let r = row(name) else { continue }
    let s = sttRows[name]
    print("  \(name): informational, median \(fmt(percentile(r.byLength[3] ?? [], 0.5)))"
        + (s.map { ", leak \($0.leak)" } ?? ""))
}
print("  L1 fail set: \(l1Fail.isEmpty ? "none" : "{" + l1Fail.joined(separator: ", ") + "}")"
    + (l1Pending.isEmpty ? "" : "  (pending STT: \(l1Pending.joined(separator: ", ")))"))

print("\nLayer 2 (VP-off speaker vs others), gate: min(his 3 s) - max(others 3 s) >= 0.20")
let his = row("clip6-vp") ?? row("clip1")
let others = ["clip9-vp", "clip5"].compactMap { row($0) }
let hisName = row("clip6-vp") != nil ? "clip 6-vp" : "clip 1"
if let his, !others.isEmpty {
    let hisMin = his.byLength[3]?.min() ?? .nan
    let othersMax = others.compactMap { $0.byLength[3]?.max() }.max() ?? .nan
    let gap = hisMin - othersMax
    let threshold = ((hisMin + othersMax) / 2 * 100).rounded() / 100
    print("  his (\(hisName)) min \(fmt(hisMin)); others max \(fmt(othersMax)); gap \(fmt(gap)) "
        + "\(gap >= 0.20 ? "PASS" : "FAIL"); candidate threshold \(String(format: "%.2f", threshold))")
    let his5 = his.byLength[5]?.min() ?? .nan, his8 = his.byLength[8]?.min() ?? .nan
    let oth5 = others.compactMap { $0.byLength[5]?.max() }.max() ?? .nan
    let oth8 = others.compactMap { $0.byLength[8]?.max() }.max() ?? .nan
    print("  5 s: his min \(fmt(his5)), others max \(fmt(oth5)); 8 s: his min \(fmt(his8)), others max \(fmt(oth8))")
} else {
    print("  n/a: needs clip 1 or 6-vp, and clip 9-vp or clip 5")
}

// Budget: capture (VP on, measured on the take) plus embedding worst case (every second of audio scored once).
let capFrac = results.compactMap { $0.clip.vp ? $0.clip.meta?.captureCPUFraction : nil }.max()
let embFrac = results.map(\.embedFraction).max() ?? 0
let totalFrac = (capFrac ?? 0) + embFrac
let rssDelta = residentMB() - rssBefore
let budgetOK = capFrac != nil && totalFrac <= budgetFraction && rssDelta <= budgetRSSMB
let embedMs = percentile(timingsMs, 0.5)
let embedP95 = percentile(timingsMs, 0.95)
print("\nbudget  capture (VP on) \(capFrac.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a")"
    + " + embed worst case \(String(format: "%.1f%%", embFrac * 100))"
    + " = \(String(format: "%.1f%%", totalFrac * 100)) of one core (rule <= 8%); "
    + "RSS +\(String(format: "%.0f", rssDelta)) MB (rule <= 80)  \(budgetOK ? "PASS" : "FLAG")")
print("embed wall ms  median \(String(format: "%.1f", embedMs))  p95 \(String(format: "%.1f", embedP95))  n=\(timingsMs.count)")
print("RSS MB  before load \(String(format: "%.0f", rssBefore))  after load \(String(format: "%.0f", rssAfterLoad))"
    + "  after scoring \(String(format: "%.0f", residentMB()))  delta \(String(format: "%.0f", rssDelta))")
print("model load s \(String(format: "%.1f", loadSeconds))   model cache \(String(format: "%.1f", directorySizeMB(modelDir))) MB")
print("\nsummary: L1 fail set \(l1Fail.isEmpty ? "none" : l1Fail.joined(separator: ",")); "
    + "budget \(budgetOK ? "PASS" : "FLAG"); determinism \(determinismHash.prefix(16))")
