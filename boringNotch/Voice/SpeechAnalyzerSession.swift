//
//  SpeechAnalyzerSession.swift
//  boringNotch
//
//  One dictation take on Apple's on-device SpeechAnalyzer. Microphone audio is
//  converted to the analyzer's format and streamed in while the shortcut is held.
//

import AVFoundation
import Defaults
import Foundation
import Speech

enum VoiceError: LocalizedError {
    case noMicrophone
    case noFormat

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone"
        case .noFormat: return "Audio format unavailable"
        }
    }
}

/// The tap's converter, built from the first buffer's real format. Only the audio thread uses it.
private final class ConverterBox: @unchecked Sendable {
    var converter: AVAudioConverter?
}

/// The buffer the take and the converter read. `.channel(n)` copies that channel's float samples into a
/// mono buffer; anything else (or a layout this copy does not handle) returns the buffer unchanged.
/// Runs on the audio thread.
private func takeMonoBuffer(_ buffer: AVAudioPCMBuffer, source: MicChannelPick.Source) -> AVAudioPCMBuffer {
    guard case .channel(let index) = source,
          index < Int(buffer.format.channelCount),
          buffer.format.commonFormat == .pcmFormatFloat32,
          !buffer.format.isInterleaved,
          let samples = buffer.floatChannelData,
          let mono = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
          let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
          let dest = out.floatChannelData
    else { return buffer }
    out.frameLength = buffer.frameLength
    dest[0].update(from: samples[index], count: Int(buffer.frameLength))
    return out
}

@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerSession: VoiceSession {
    private let engine = AVAudioEngine()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finals: [String] = []
    /// Measures what the mic delivers. Read by the manager's verdict and by the take report.
    let levelTap = MicLevelTap()
    private(set) var tapChannels = -1
    private(set) var tapSampleRate = -1
    private var partialCount = 0
    private var finalizeMs = -1
    private var finalized = false
    /// The transcriber's latest unconfirmed text. Used only if finalize does not finish in time.
    private var lastVolatile = ""
    private var configObserver: NSObjectProtocol?
    /// The take's audio as 16 kHz PCM, for the cloud transcript.
    private let audio = TakeAudioBuffer()
    /// Uptime when the engine started and when the first partial arrived, for the take report.
    private var engineStartedAt: TimeInterval?
    private var firstPartialAt: TimeInterval?
    /// True when the take runs with Apple voice processing (echo cancellation, noise suppression, AGC).
    private(set) var voiceProcessing = false
    /// True when this take paused the Mac's music, so teardown resumes only what it paused.
    private var pausedMedia = false

    /// Makes sure the on-device en_US model is installed. The OS fetches it once.
    /// `onDownloadStart` runs only when a download is actually needed, so the UI can say so.
    func prepareModel(onDownloadStart: @MainActor @escaping () -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .progressiveTranscription)
        self.transcriber = transcriber
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onDownloadStart()
            try await request.downloadAndInstall()
        }
    }

    func start(contextualStrings: [String], onPartial: @escaping @Sendable (String) -> Void) async throws {
        let transcriber = self.transcriber
            ?? SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .progressiveTranscription)
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.noFormat
        }

        // Dictionary words bias Apple's recognizer toward the spelling the user typed.
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(context)
        }

        let input = engine.inputNode
        // Before the format is read: voice processing changes the input format the tap sees.
        if Defaults[.dictationVoiceProcessing] {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .min)
                voiceProcessing = true
            } catch {
                voiceProcessing = false
            }
        }
        var inFormat = input.outputFormat(forBus: 0)
        if voiceProcessing, !(inFormat.channelCount > 0 && MicLevelMeter.isUsableRate(inFormat.sampleRate)) {
            // A voice-processing format the take can't use: fall back to the raw mic instead of failing the take.
            try? input.setVoiceProcessingEnabled(false)
            voiceProcessing = false
            inFormat = input.outputFormat(forBus: 0)
        }
        guard inFormat.channelCount > 0, MicLevelMeter.isUsableRate(inFormat.sampleRate) else {
            throw VoiceError.noMicrophone
        }
        tapChannels = Int(inFormat.channelCount)
        tapSampleRate = Int(inFormat.sampleRate)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let tap = levelTap
        let converterBox = ConverterBox()
        let takeAudio = audio
        let usesVoiceProcessing = voiceProcessing
        // The format comes from the first buffer, not from the input node at start. CoreAudio can
        // still be switching devices then, and a tap installed with the stale format delivers nothing.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            tap.ingest(buffer)
            // With voice processing the input has several channels and channel 0 is the processed voice.
            // Without it this is the buffer itself (passthrough or downmix, as before).
            let mono = takeMonoBuffer(
                buffer,
                source: MicChannelPick.monoSource(
                    channelCount: Int(buffer.format.channelCount), voiceProcessing: usesVoiceProcessing))
            takeAudio.ingest(mono)
            let format = mono.format
            // The device can change after start, so a buffer may carry a rate the start check never saw.
            guard MicLevelMeter.isUsableRate(format.sampleRate) else {
                tap.noteConvertFailure()
                return
            }
            if converterBox.converter?.inputFormat != format {
                converterBox.converter = AVAudioConverter(from: format, to: target)
            }
            guard let converter = converterBox.converter else {
                tap.noteConvertFailure()
                return
            }
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(mono.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return mono
            }
            if status == .error {
                tap.noteConvertFailure()
                return
            }
            guard out.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: out))
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [tap] _ in tap.noteConfigChange() }

        self.analyzer = analyzer
        self.continuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self?.finals.append(text)
                        self?.lastVolatile = ""
                    } else {
                        self?.lastVolatile = text
                        self?.partialCount += 1
                        if self?.firstPartialAt == nil { self?.firstPartialAt = ProcessInfo.processInfo.systemUptime }
                        onPartial(text)
                    }
                }
            } catch {
                // A failed results stream ends the take with whatever was final.
            }
        }

        do {
            if Defaults[.dictationPausesMedia], MusicManager.shared.isPlaying {
                MusicManager.shared.pause()
                pausedMedia = true
            }
            engine.prepare()
            engineStartedAt = ProcessInfo.processInfo.systemUptime
            do {
                try engine.start()
            } catch where voiceProcessing {
                // Voice processing failed to start: retry on the raw mic so the take never fails for it.
                try? input.setVoiceProcessingEnabled(false)
                voiceProcessing = false
                engine.prepare()
                let rawFormat = input.outputFormat(forBus: 0)
                tapChannels = Int(rawFormat.channelCount)
                tapSampleRate = Int(rawFormat.sampleRate)
                try engine.start()
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            teardownAudio()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    func finish() async throws -> [String] {
        teardownAudio()
        if let analyzer {
            let startedAt = ProcessInfo.processInfo.systemUptime
            // Cap the wait so the notch can never stick on "Transcribing".
            let result = await TimeoutRace.run(seconds: 2) {
                (try? await analyzer.finalizeAndFinishThroughEndOfInput()) != nil
            }
            finalizeMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            finalized = result == true
            if !finalized {
                _ = await TimeoutRace.run(seconds: 0.5) { await analyzer.cancelAndFinishNow() }
            }
        }
        if let resultsTask {
            // A drain that times out may have missed the last final. Treat the take as not
            // finalized, so the unconfirmed volatile tail is kept instead of dropped.
            let drained = await TimeoutRace.run(seconds: 0.5) { await resultsTask.value }
            if drained == nil { finalized = false }
        }
        return TranscriptAssembler.parts(finals: finals, volatileTail: lastVolatile, finalized: finalized)
    }

    /// Stops the microphone at key release without waiting for the analyzer. Returns the transcript so far.
    /// `finish()` still runs afterwards for the final results.
    func stopNow() -> [String] {
        teardownAudio()
        return TranscriptAssembler.parts(finals: finals, volatileTail: lastVolatile, finalized: false)
    }

    /// The take's audio as a WAV file, or nil when no audio arrived.
    func takeWAV() -> Data? {
        audio.wav()
    }

    func cancel() async {
        teardownAudio()
        if let analyzer {
            _ = await TimeoutRace.run(seconds: 0.5) { await analyzer.cancelAndFinishNow() }
        }
        if let resultsTask {
            _ = await TimeoutRace.run(seconds: 0.5) { await resultsTask.value }
        }
        finals.removeAll()
    }

    /// Adds this take's audio and transcript numbers to the report.
    func fill(_ report: inout TakeReport) {
        report.tapChannels = tapChannels
        report.tapSampleRate = tapSampleRate
        report.finals = finals.count
        report.partials = partialCount
        report.finalizeMs = finalizeMs
        report.voiceProcessing = voiceProcessing
        report.volatileTail = !finalized && !lastVolatile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let engineStartedAt, let firstPartialAt {
            report.firstPartialMs = Int((firstPartialAt - engineStartedAt) * 1000)
        }
        levelTap.fill(&report)
    }

    private func teardownAudio() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if pausedMedia {
            pausedMedia = false
            MusicManager.shared.play()
        }
        continuation?.finish()
        continuation = nil
    }
}
