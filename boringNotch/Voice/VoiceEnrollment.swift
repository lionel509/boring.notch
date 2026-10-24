//
//  VoiceEnrollment.swift
//  boringNotch
//
//  Learns Lionel's voice (#17 U3). Three read prompts are recorded through the same input graph as a take
//  (`SpeechAnalyzerSession.makeInputGraph`, Voice Isolation included), each prompt is scored by the one path
//  (`SpeakerGate.segmentEmbedding`, which normalises first and runs in the XPC helper), and the voiceprint is
//  the centroid of the three. The voiceprint is stored on this Mac and is read only by the take and this file.
//

import AVFoundation
import Defaults
import Foundation
import SwiftUI

enum VoiceEnrollmentError: Error {
    case noMicrophone
}

/// The stored voiceprint. Forget clears it and the time it was learned, so the take transcribes every voice.
/// Not availability-gated: Settings calls it on every macOS.
enum VoiceprintStore {
    static func forget() {
        Defaults[.dictationVoiceprint] = []
        Defaults[.dictationVoiceEnrolledAt] = nil
    }
}

@available(macOS 26.0, *)
@MainActor
final class VoiceEnrollment: ObservableObject {
    /// The three prompts, as in the spike round (#18), so the enrolment reads what the spike measured.
    static let prompts = [
        "The quick brown fox jumps over the lazy dog while the notch listens to every word I say.",
        "Please schedule the meeting for Tuesday afternoon and send the notes to the whole team.",
        "Seven green apples, two blue bicycles and one very tired cat were waiting at the station.",
    ]
    /// Each prompt records at most this long; the take's span for an enrolment prompt.
    static let recordSeconds: Double = 8

    /// The flow itself (steps, level gate, retry limit) lives in `EnrollmentLogic`; this class only drives the mic.
    @Published private(set) var state = EnrollmentLogic.State()
    /// The live mic level (0...1) for the bars while a prompt records.
    @Published private(set) var level: Float = 0

    var step: EnrollmentLogic.Step { state.step }
    var message: String? { state.message }

    private var clips: [[Float]] = []
    private var engine: AVAudioEngine?
    /// Whether the open engine turned voice processing on, so teardown switches it off again.
    private var usesVoiceProcessing = false
    private var take: TakeAudioBuffer?
    private var autoStop: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    /// Starts recording the current prompt. It stops by itself after `recordSeconds`, or early through `stopPrompt()`.
    func startPrompt() {
        guard case .prompt = step else { return }
        let buffer = TakeAudioBuffer()
        do {
            try startEngine(into: buffer)
        } catch {
            EnrollmentLogic.reduce(&state, .fail("No microphone is available. Check the input in System Settings."))
            return
        }
        take = buffer
        EnrollmentLogic.reduce(&state, .start)
        autoStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.recordSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopPrompt()
        }
    }

    /// Ends the recording of the current prompt and checks its level. A quiet prompt repeats; an accepted one
    /// moves on; the third accepted prompt starts the scoring.
    func stopPrompt() {
        guard case .recording = step, let buffer = take else { return }
        autoStop?.cancel()
        autoStop = nil
        teardownEngine()
        take = nil
        let samples = buffer.samples(from: 0, to: Self.recordSeconds)
        let clipsBefore = state.clips
        EnrollmentLogic.reduce(&state, .stop(levelDBFS: SpeakerGate.levelDBFS(samples)))
        if state.clips > clipsBefore { clips.append(samples) }
        if case .computing = step { Task { await compute() } }
    }

    /// Stops any recording and drops the enrolment in progress. Called when the sheet closes.
    func close() {
        autoStop?.cancel()
        autoStop = nil
        teardownEngine()
        take = nil
        clips = []
        EnrollmentLogic.reduce(&state, .close)
    }

    /// Scores the three clips through the one path, checks they agree, and saves the centroid as the voiceprint.
    private func compute() async {
        let id = UUID()
        await FluidSpeakerEmbedder.shared.beginTake(id)
        var embeddings: [[Float]] = []
        do {
            for clip in clips {
                guard let embedding = try await FluidSpeakerEmbedder.shared.segmentEmbedding(clip, take: id) else {
                    await FluidSpeakerEmbedder.shared.release(id)
                    EnrollmentLogic.reduce(&state, .scored(false))
                    return
                }
                embeddings.append(embedding)
            }
        } catch {
            await FluidSpeakerEmbedder.shared.release(id)
            EnrollmentLogic.reduce(&state, .fail(EnrollmentLogic.modelUnavailableMessage))
            return
        }
        await FluidSpeakerEmbedder.shared.release(id)

        guard let voiceprint = EnrollmentLogic.assemble(embeddings) else {
            EnrollmentLogic.reduce(&state, .scored(false))
            return
        }
        Defaults[.dictationVoiceprint] = voiceprint
        Defaults[.dictationVoiceEnrolledAt] = .now
        clips = []
        EnrollmentLogic.reduce(&state, .scored(true))
    }

    /// The same graph a take builds: voice processing first (its ducking stays at `.mid`, music is never paused),
    /// then `makeInputGraph`, then the tap feeds the meter and the prompt's buffer.
    private func startEngine(into buffer: TakeAudioBuffer) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var voiceProcessing = false
        if Defaults[.dictationVoiceProcessing] {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .mid)
                voiceProcessing = true
            } catch {
                voiceProcessing = false
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0, MicLevelMeter.isUsableRate(inFormat.sampleRate) else {
            if voiceProcessing { try? input.setVoiceProcessingEnabled(false) }
            throw VoiceEnrollmentError.noMicrophone
        }

        let graph = SpeechAnalyzerSession.makeInputGraph(engine: engine)
        let meter = MicLevelTap()
        let format: AVAudioFormat? = graph.isolation ? graph.tapNode.outputFormat(forBus: 0) : nil
        let usesVP = voiceProcessing
        graph.tapNode.installTap(onBus: 0, bufferSize: 4096, format: format) { pcm, _ in
            meter.ingest(pcm)
            buffer.ingest(Self.channelZero(pcm, voiceProcessing: usesVP))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            graph.tapNode.removeTap(onBus: 0)
            if voiceProcessing { try? input.setVoiceProcessingEnabled(false) }
            throw error
        }
        self.engine = engine
        usesVoiceProcessing = voiceProcessing
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self else { return }
                self.level = meter.level
            }
        }
    }

    private func teardownEngine() {
        meterTask?.cancel()
        meterTask = nil
        level = 0
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Voice processing is switched off on every exit, as in a take (#17 U2b).
        if usesVoiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        usesVoiceProcessing = false
        self.engine = nil
    }

    /// With voice processing the input has several channels and channel 0 is the processed voice (`MicChannelPick`).
    /// Anything else passes through unchanged for `TakeAudioBuffer` to convert.
    private static func channelZero(_ buffer: AVAudioPCMBuffer, voiceProcessing: Bool) -> AVAudioPCMBuffer {
        guard MicChannelPick.monoSource(channelCount: Int(buffer.format.channelCount), voiceProcessing: voiceProcessing) == .channel(0),
              let source = buffer.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let target = out.floatChannelData else { return buffer }
        out.frameLength = buffer.frameLength
        target[0].update(from: source[0], count: Int(buffer.frameLength))
        return out
    }
}

/// The enrolment sheet: the prompt to read, live bars, and Start / Stop / Done.
@available(macOS 26.0, *)
struct VoiceEnrollmentView: View {
    @StateObject private var enrollment = VoiceEnrollment()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learn my voice").font(.headline)
            switch enrollment.step {
            case .prompt(let index), .recording(let index):
                Text("Read this \(index + 1) of \(VoiceEnrollment.prompts.count), at your normal speaking distance.")
                    .foregroundStyle(.secondary)
                Text(VoiceEnrollment.prompts[index])
                    .fixedSize(horizontal: false, vertical: true)
                bars
                if let message = enrollment.message {
                    Text(message).foregroundStyle(.orange)
                }
            case .computing:
                Text("Learning your voice…").foregroundStyle(.secondary)
            case .done:
                Text("Done. Your voice is learned and stays on this Mac.")
            case .failed(let reason):
                Text(reason).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                switch enrollment.step {
                case .prompt:
                    Button("Start") { enrollment.startPrompt() }
                        .keyboardShortcut(.defaultAction)
                case .recording:
                    Button("Stop") { enrollment.stopPrompt() }
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Try again") { enrollment.close() }
                case .computing:
                    EmptyView()
                case .done:
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Cancel") {
                    enrollment.close()
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { enrollment.close() }
    }

    private var bars: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(MicBars.levels(level: enrollment.level, time: 0, count: 7, ripple: false).enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(.secondary)
                    .frame(width: 6, height: max(4, CGFloat(value) * 28))
            }
        }
        .frame(height: 28)
    }
}
