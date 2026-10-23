import Foundation
import XCTest

/// Breaker round 5, unit U3 (voice processing, media pause) against PR #15 at head 90f917a.
/// These are source-reading tests: the capture path lives in the app target, outside this package.
/// Red on 90f917a is the point.
final class BreakerR5U3Tests: XCTestCase {

    /// Path to the app sources from this file: <root>/Tests/VoiceDictationLogicTests/<file>.
    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text from one marker up to the next, without parsing Swift.
    private func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start) else { return nil }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    /// U3-1. Voice processing is on, the input then reports a 0-channel (or unusable-rate) format, and
    /// `start` throws `noMicrophone`. The plan says "A VP failure falls back to the raw mic and never fails
    /// the take", but the only fallback is on `engine.start()` failure. Here voice processing stays on and the
    /// take fails. Repro: enable VP on a device whose VP format reports 0 channels.
    /// Expected: voice processing is switched off and the format re-read before the guard gives up.
    func testVoiceProcessingBadFormatFallsBackInsteadOfFailingTheTake() throws {
        let text = try appSource("boringNotch/Voice/SpeechAnalyzerSession.swift")
        let region = between(text, "if Defaults[.dictationVoiceProcessing] {", "throw VoiceError.noMicrophone") ?? ""
        XCTAssertFalse(region.isEmpty, "the VP block or the noMicrophone throw moved; re-check this test")
        XCTAssertTrue(
            region.contains("setVoiceProcessingEnabled(false)"),
            "a VP format with 0 channels or an unusable rate throws noMicrophone with voice processing still on; the plan requires a raw-mic retry so VP never fails the take")
    }

    /// U3-2. The raw-mic retry after a failed `engine.start()` switches voice processing off, so the input
    /// format changes (#8/#9/#12 class). The take report keeps the channel count and rate from the VP format,
    /// and the format is not validated again. Repro: force `engine.start()` to throw with VP on, then read
    /// `take.tapChannels` / `tapSampleRate` in the report.
    /// Expected: the retry path re-reads the input format and updates tapChannels / tapSampleRate.
    func testVoiceProcessingRetryRefreshesTapFormat() throws {
        let text = try appSource("boringNotch/Voice/SpeechAnalyzerSession.swift")
        let retry = between(text, "} catch where voiceProcessing {", "try await analyzer.start(inputSequence") ?? ""
        XCTAssertFalse(retry.isEmpty, "the VP retry block moved; re-check this test")
        XCTAssertTrue(
            retry.contains("tapChannels") && retry.contains("tapSampleRate"),
            "the raw-mic retry disables VP but never updates tapChannels/tapSampleRate, so the take report describes the VP format for a raw-mic take")
    }

    /// U3-3. The tap closure hands every buffer to `TakeAudioBuffer.ingest` before the sample-rate gate runs.
    /// `TakeAudioBuffer` computes `16000 / buffer rate` and uses it as an `AVAudioFrameCount`, which traps when
    /// the value does not fit. MicLevelMeter's own comment says a sub-kHz rate overflows the converter capacity,
    /// so the gate exists for exactly this, yet it runs after the ingest it guards.
    /// Reachability: a rate under roughly 0.015 Hz or a device switch that reports one. Not proven on hardware.
    /// Expected: the `isUsableRate(format.sampleRate)` gate is checked before `takeAudio.ingest(buffer)`.
    func testSampleRateGateRunsBeforeTakeAudioIngest() throws {
        let text = try appSource("boringNotch/Voice/SpeechAnalyzerSession.swift")
        let tap = between(text, "input.installTap(onBus: 0", "configObserver = ") ?? ""
        guard let gate = tap.range(of: "MicLevelMeter.isUsableRate(format.sampleRate)"),
              let ingest = tap.range(of: "takeAudio.ingest(buffer)") else {
            return XCTFail("the tap closure moved; re-check this test")
        }
        XCTAssertLessThan(
            gate.lowerBound, ingest.lowerBound,
            "TakeAudioBuffer.ingest runs before the usable-rate gate, so a rate the gate rejects still reaches the frame-capacity math")
    }
}
