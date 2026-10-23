// STT accuracy bench (#13, v2 item 8). Records scripted takes, then scores Apple SpeechAnalyzer
// against the two OpenRouter STT models on word error rate, latency and cost.
// Build: swiftc -O -swift-version 5 -framework Speech -framework AVFoundation \
//          scripts/stt-bench/main.swift boringNotch/Voice/Logic/WordErrorRate.swift \
//          -o ~/worktrees/boring.notch/.target/stt-bench
// Usage: stt-bench [--vp] [refs.txt]
//   --vp  record with Apple voice processing on (echo cancellation, noise suppression), to measure music bleed.
// Audio and transcripts stay in the scratch dir and are deleted at the end. Only the numbers table
// is printed. The key is read from ~/.config/openrouter-key and is never printed or logged.
import AVFoundation
import Foundation
import Speech

let sttModels = ["assemblyai/universal-3-6-pro", "mistralai/voxtral-mini-transcribe-3-0"]
let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
let keyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/openrouter-key")
let scratch = URL(fileURLWithPath: (NSHomeDirectory() as NSString)
    .appendingPathComponent("worktrees/boring.notch/.target/stt-bench-scratch"))

struct Take {
    let index: Int
    let reference: String
    let seconds: Double
    var appleWER = 1.0
    var appleMs = -1
    var appleErr = ""
    var assemblyWER = 1.0
    var assemblyMs = -1
    var assemblyUSD = 0.0
    var voxtralWER = 1.0
    var voxtralMs = -1
    var voxtralUSD = 0.0
}

func readKey() -> String? {
    guard let raw = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
}

/// Records one take to a 16 kHz mono 16-bit WAV. Return starts and stops it.
func recordTake(to url: URL) throws -> Double {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if CommandLine.arguments.contains("--vp") {
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .min)
        print("voice processing: on")
    }
    let inFormat = input.outputFormat(forBus: 0)
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                        channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
        throw NSError(domain: "bench", code: 1)
    }
    let file = try AVAudioFile(forWriting: url, settings: outFormat.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
    var frames: AVAudioFrameCount = 0
    input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inFormat.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        try? file.write(from: out)
        frames += out.frameLength
    }
    engine.prepare()
    try engine.start()
    _ = readLine()  // Return to stop
    engine.stop()
    input.removeTap(onBus: 0)
    return Double(frames) / 16_000
}

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

/// One OpenRouter transcription. Returns the text and the STT cost from usage.cost.
func openRouterTranscribe(_ url: URL, model: String, key: String) async throws -> (String, Double) {
    let base64 = try Data(contentsOf: url).base64EncodedString()
    var request = URLRequest(url: endpoint, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["model": model, "input_audio": ["data": base64, "format": "wav"]]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(domain: "openrouter", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = json["text"] as? String else {
        throw NSError(domain: "openrouter", code: -2)
    }
    let usage = json["usage"] as? [String: Any]
    let cost = usage?["cost"] as? Double ?? 0
    return (text, cost)
}

func timed<T>(_ work: () async throws -> T) async rethrows -> (T, Int) {
    let start = Date()
    let value = try await work()
    return (value, Int(Date().timeIntervalSince(start) * 1000))
}

func run() async {
    let refsPath = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "scripts/stt-bench/refs.txt"
    guard let refsText = try? String(contentsOfFile: refsPath, encoding: .utf8) else {
        print("cannot read \(refsPath)"); return
    }
    let refs = refsText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    guard let key = readKey() else { print("no key at the expected path"); return }
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    var takes: [Take] = []
    for (i, ref) in refs.enumerated() {
        print("\nTake \(i + 1)/\(refs.count). Read aloud, then press Return to stop:\n\(ref)")
        _ = readLine()  // Return to start
        let url = scratch.appendingPathComponent("take\(i + 1).wav")
        do {
            let seconds = try recordTake(to: url)
            var take = Take(index: i + 1, reference: ref, seconds: seconds)
            if let (text, ms) = try? await timed({ try await appleTranscribe(url) }) {
                take.appleWER = WordErrorRate.wer(reference: ref, hypothesis: text)
                take.appleMs = ms
            } else {
                take.appleErr = "fail"
            }
            for model in sttModels {
                let isAssembly = model.hasPrefix("assemblyai")
                do {
                    let ((text, cost), ms) = try await timed({ try await openRouterTranscribe(url, model: model, key: key) })
                    let wer = WordErrorRate.wer(reference: ref, hypothesis: text)
                    if isAssembly {
                        take.assemblyWER = wer; take.assemblyMs = ms; take.assemblyUSD = cost
                    } else {
                        take.voxtralWER = wer; take.voxtralMs = ms; take.voxtralUSD = cost
                    }
                } catch {
                    // Failure is recorded as WER 1.0 with ms -1; the status code is printed, never the body.
                    print("take \(i + 1): \(model) failed with code \((error as NSError).code)")
                }
            }
            takes.append(take)
            try? FileManager.default.removeItem(at: url)
        } catch {
            print("take \(i + 1): recording failed")
        }
    }

    print("\ntake,seconds,apple_wer,assemblyai_wer,voxtral_wer,apple_ms,assemblyai_ms,voxtral_ms,assemblyai_usd,voxtral_usd")
    for t in takes {
        let row = [String(t.index), String(format: "%.1f", t.seconds),
                   String(format: "%.3f", t.appleWER), String(format: "%.3f", t.assemblyWER),
                   String(format: "%.3f", t.voxtralWER), String(t.appleMs), String(t.assemblyMs),
                   String(t.voxtralMs), String(format: "%.5f", t.assemblyUSD), String(format: "%.5f", t.voxtralUSD)]
        print(row.joined(separator: ","))
    }
    guard !takes.isEmpty else { return }
    let n = Double(takes.count)
    let meanApple = takes.map(\.appleWER).reduce(0, +) / n
    let meanAssembly = takes.map(\.assemblyWER).reduce(0, +) / n
    let meanVoxtral = takes.map(\.voxtralWER).reduce(0, +) / n
    print("\nmean WER: apple \(String(format: "%.3f", meanApple)), assemblyai \(String(format: "%.3f", meanAssembly)), voxtral \(String(format: "%.3f", meanVoxtral))")
    let assemblyPer100 = takes.map(\.assemblyUSD).reduce(0, +) / n * 100
    let voxtralPer100 = takes.map(\.voxtralUSD).reduce(0, +) / n * 100
    print("$ per 100 takes (STT only): assemblyai \(String(format: "%.4f", assemblyPer100)), voxtral \(String(format: "%.4f", voxtralPer100)), apple 0")
    try? FileManager.default.removeItem(at: scratch)
}

Task {
    await run()
    exit(0)
}
RunLoop.main.run()
