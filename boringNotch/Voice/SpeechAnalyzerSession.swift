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

@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerSession: VoiceSession {
    private let engine = AVAudioEngine()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finals: [String] = []

    func start(onPartial: @escaping @Sendable (String) -> Void) async throws {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.noFormat
        }

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else {
            throw VoiceError.noMicrophone
        }
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw VoiceError.noFormat
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let ratio = target.sampleRate / inFormat.sampleRate
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
            guard status != .error, out.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: out))
        }

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.continuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self?.finals.append(text)
                    } else {
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
            // Cap the wait so the notch can never stick on "Transcribing".
            let finalized = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    try? await analyzer.finalizeAndFinishThroughEndOfInput()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !finalized {
                await analyzer.cancelAndFinishNow()
            }
        }
        await resultsTask?.value
        return finals
    }

    func cancel() async {
        teardownAudio()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
        finals.removeAll()
    }

    private func teardownAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
