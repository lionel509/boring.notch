// --voice-only (#17 U0 round 5): records Lionel's three prompts as me1, me2, me3 (8 s each, VP off). Never reads
// stdin: the countdown and the sounds replace Return, so it works from a non-TTY shell. Each take runs Apple STT
// and is scored by WER against its prompt; a WER above 0.5 is redone (two retries). The transcript is never printed.
import AppKit
import AVFoundation
import Foundation
import Speech
import VoiceDictationLogic

let voicePrompts: [(name: String, text: String)] = [("me1", promptA), ("me2", promptB), ("me3", promptC)]
let voiceSeconds = 8.0
let voiceRetries = 2
let voiceWERLimit = 0.5

func playSound(_ name: String) {
    NSSound(named: NSSound.Name(name))?.play()
}

/// Countdown 3, 2, 1, SPEAK (Tink), 8 s of capture, then Pop. Nothing is read from stdin.
func recordVoicePrompt(_ text: String) -> TakeResult {
    print("  Read aloud: \(text)")
    for n in [3, 2, 1] {
        print("  \(n)…")
        Thread.sleep(forTimeInterval: 1)
    }
    print("  SPEAK")
    playSound("Tink")
    let take = captureRound1(seconds: voiceSeconds)
    playSound("Pop")
    return take
}

/// Records the three prompts, one at a time. For each, the best of up to three attempts (lowest WER) is kept.
@available(macOS 26.0, *)
func recordVoiceOnly() async throws {
    for (name, text) in voicePrompts {
        var best: (wer: Double, url: URL, meta: CaptureMeta)? = nil
        for attempt in 0...voiceRetries {
            print("\nTake \(name), attempt \(attempt + 1) of \(voiceRetries + 1)")
            let take = recordVoicePrompt(text)
            guard !take.samples.isEmpty else {
                print("  FAILED: \(take.failure ?? "no audio")")
                continue
            }
            let url = scratch.appendingPathComponent("\(name)-try\(attempt + 1).wav")
            try saveClip(take.samples, to: url)
            // WER only; the transcript text stays in this scope.
            let wer: Double
            do {
                let transcript = try await appleTranscribe(url)
                wer = WordErrorRate.wer(reference: text, hypothesis: transcript)
            } catch {
                print("  STT failed on this take: \(error)")
                wer = 1.0
            }
            print("  WER \(String(format: "%.3f", wer)), level \(String(format: "%.1f", take.meta.levelDBFS)) dBFS, "
                + "capture CPU \(String(format: "%.1f", take.meta.captureCPUFraction * 100))% of one core")
            if best == nil || wer < best!.wer { best = (wer, url, take.meta) }
            if wer <= voiceWERLimit { break }
            if attempt < voiceRetries {
                print("  Didn't hear the prompt — redo")
            } else {
                print("  Still above \(voiceWERLimit) after \(voiceRetries) retries: keeping the best take")
            }
        }
        guard let keep = best else { throw SpikeError.missingClip(name) }
        let target = clipURL(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: keep.url, to: target)
        try JSONEncoder().encode(keep.meta).write(to: metaURL(name))
        print("Saved \(name).wav (WER \(String(format: "%.3f", keep.wer)), level "
            + "\(String(format: "%.1f", keep.meta.levelDBFS)) dBFS)")
    }
    print("\nDone. Next: speaker-spike --stt --seq --diarizer, and --mix for the offline mix table.")
}
