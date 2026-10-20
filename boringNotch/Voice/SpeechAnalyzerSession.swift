//
//  SpeechAnalyzerSession.swift
//  boringNotch
//
//  One dictation take on Apple's on-device SpeechAnalyzer. Microphone audio is
//  converted to the analyzer's format and streamed in while the shortcut is held.
//

import AVFoundation
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
    private var configObserver: NSObjectProtocol?

    /// Makes sure the on-device en_US model is installed. The OS fetches it once.
    /// `onDownloadStart` runs only when a download is actually needed, so the UI can say so.
    func prepareModel(onDownloadStart: @MainActor @escaping () -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .transcription)
        self.transcriber = transcriber
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onDownloadStart()
            try await request.downloadAndInstall()
        }
    }

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        let transcriber = self.transcriber
            ?? SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .transcription)
        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.noFormat
        }

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else {
            throw VoiceError.noMicrophone
        }
        tapChannels = Int(inFormat.channelCount)
        tapSampleRate = Int(inFormat.sampleRate)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let tap = levelTap
        let converterBox = ConverterBox()
        // The format comes from the first buffer, not from the input node at start. CoreAudio can
        // still be switching devices then, and a tap installed with the stale format delivers nothing.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            tap.ingest(buffer)
            let format = buffer.format
            if converterBox.converter?.inputFormat != format {
                converterBox.converter = AVAudioConverter(from: format, to: target)
            }
            guard let converter = converterBox.converter else {
                tap.noteConvertFailure()
                return
            }
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
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
                return buffer
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
                    } else {
                        self?.partialCount += 1
                        onPartial(text)
                    }
                }
            } catch {
                // A failed results stream ends the take with whatever was final.
            }
        }

        do {
            engine.prepare()
            try engine.start()
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
            _ = await TimeoutRace.run(seconds: 0.5) { await resultsTask.value }
        }
        return finals
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
        report.volatileTail = false
        levelTap.fill(&report)
    }

    private func teardownAudio() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
