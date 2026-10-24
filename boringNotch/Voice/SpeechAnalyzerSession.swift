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

/// The tap's converter, built from the first buffer's real format, and the take's mono source (#17 U2b).
/// Only the audio thread uses it.
private final class ConverterBox: @unchecked Sendable {
    var converter: AVAudioConverter?
    /// Chosen by the first buffer and kept for the take.
    var source: MicChannelPick.Source?
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

/// The take's mono source for one tap buffer (#17 U2b). The first buffer decides for the whole take: with voice
/// processing that is channel 0, unless channel 0 sits more than 20 dB below the loudest channel. Runs on the
/// audio thread.
private func takeSource(for buffer: AVAudioPCMBuffer, voiceProcessing: Bool, box: ConverterBox) -> MicChannelPick.Source {
    if let source = box.source { return source }
    var source = MicChannelPick.monoSource(channelCount: Int(buffer.format.channelCount), voiceProcessing: voiceProcessing)
    if source == .channel(0), let rms = channelRMS(buffer), MicChannelPick.needsLoudest(rms: rms) {
        source = .channel(MicChannelPick.loudest(rms: rms))
    }
    box.source = source
    return source
}

/// RMS of each channel of a float buffer, or nil when the buffer has no float samples.
private func channelRMS(_ buffer: AVAudioPCMBuffer) -> [Float]? {
    guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData, buffer.frameLength > 0 else {
        return nil
    }
    let count = Int(buffer.frameLength)
    return (0..<Int(buffer.format.channelCount)).map { channel in
        var sum: Float = 0
        for index in 0..<count { sum += data[channel][index] * data[channel][index] }
        return (sum / Float(count)).squareRoot()
    }
}

/// A transcriber result's span in take seconds. A non-finite or inverted range is the whole take so far.
private func spanSeconds(_ range: CMTimeRange, total: Double) -> (start: Double, end: Double) {
    let start = range.start.seconds
    let end = range.end.seconds
    guard start.isFinite, end.isFinite, end >= start else { return (0, total) }
    return (start, end)
}

/// Process CPU seconds and resident megabytes for the take report (#17 U2b). Read through the kernel, never `ps`.
private enum ProcessMeter {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1_048_576)
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
    /// The finals with their spans and speaker embeddings, and the volatile tail, as the results loop builds them (#17 U2b).
    private var transcript = TakeTranscript()
    /// Identifies this take to the speaker embedder's lease (#17 U2b, round 2).
    private let takeID = UUID()
    /// The voiceprint, read once at start. Empty until enrolment.
    private var voiceprint: [Float] = []
    /// The take's speaker mode, read at key release, and the labelling it produced for the paste and the WAV.
    private var mode: SpeakerMode = .onlyMe
    private var labelled: [LabelledSegment] = []
    /// The node the tap sits on: the Voice Isolation effect when it was built, else the input.
    private var tapNode: AVAudioNode?
    /// Measures what the mic delivers. Read by the manager's verdict and by the take report.
    let levelTap = MicLevelTap()
    private(set) var tapChannels = -1
    private(set) var tapSampleRate = -1
    private var partialCount = 0
    private var finalizeMs = -1
    private var finalized = false
    private var configObserver: NSObjectProtocol?
    /// The take's audio as 16 kHz PCM, for the cloud transcript.
    private let audio = TakeAudioBuffer()
    /// Uptime when the engine started and when the first partial arrived, for the take report.
    private var engineStartedAt: TimeInterval?
    private var firstPartialAt: TimeInterval?
    /// True when the take runs with Apple voice processing (echo cancellation, noise suppression, AGC).
    private(set) var voiceProcessing = false
    /// True when the take runs through the Voice Isolation effect (#17 U2b).
    private(set) var isolation = false
    /// True when this take paused the Mac's music, so teardown resumes only what it paused.
    private var pausedMedia = false
    /// Process CPU and resident memory when the engine started, and the take's CPU share and memory change at key release.
    private var cpuAtStart = 0.0
    private var rssAtStart = 0
    private var cpuPct = -1.0
    private var rssDeltaMB = -1
    /// Resident memory 5 s after key release, as a change from the start of the take (#17 U2b).
    private var idleTask: Task<Int, Never>?

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

    /// The take's input graph (#17 U2b): with voice processing on, the Voice Isolation effect sits between the
    /// input and the mixer, and the tap reads the effect's output so every consumer sees the isolated audio.
    /// If the effect cannot be built the tap stays on the input and `isolation` is false. Connects only; the
    /// caller installs the tap.
    static func makeInputGraph(engine: AVAudioEngine) -> (tapNode: AVAudioNode, isolation: Bool) {
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled else { return (input, false) }
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        engine.attach(effect)
        engine.connect(input, to: effect, format: input.outputFormat(forBus: 0))
        engine.connect(effect, to: engine.mainMixerNode, format: nil)
        // The engine runs for the tap alone; nothing is played back through it.
        engine.mainMixerNode.outputVolume = 0
        return (effect, true)
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

        voiceprint = Defaults[.dictationVoiceprint].map { Float($0) }
        let input = engine.inputNode
        // Before the format is read: voice processing changes the input format the tap sees.
        if Defaults[.dictationVoiceProcessing] {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Ducking stays at `.mid`, never pausing: the music keeps playing, quieter, during the take.
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .mid)
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

        let graph = Self.makeInputGraph(engine: engine)
        tapNode = graph.tapNode
        isolation = graph.isolation

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let tap = levelTap
        let converterBox = ConverterBox()
        let takeAudio = audio
        let usesVoiceProcessing = voiceProcessing
        // The format comes from the first buffer, not from the input node at start. CoreAudio can
        // still be switching devices then, and a tap installed with the stale format delivers nothing.
        // The isolation effect has a fixed format, so its tap takes the explicit one.
        let onBuffer: AVAudioNodeTapBlock = { buffer, _ in
            tap.ingest(buffer)
            // With voice processing the input has several channels and channel 0 is the processed voice.
            // Without it this is the buffer itself (passthrough or downmix, as before).
            let mono = takeMonoBuffer(
                buffer,
                source: takeSource(for: buffer, voiceProcessing: usesVoiceProcessing, box: converterBox))
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
        graph.tapNode.installTap(
            onBus: 0, bufferSize: 4096, format: graph.isolation ? graph.tapNode.outputFormat(forBus: 0) : nil,
            block: onBuffer)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [tap] _ in tap.noteConfigChange() }

        self.analyzer = analyzer
        self.continuation = continuation

        await FluidSpeakerEmbedder.shared.beginTake(takeID)
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let span = spanSeconds(result.range, total: takeAudio.seconds)
                    if result.isFinal {
                        guard let self else { continue }
                        // The text is kept before the embedding is awaited, so the final is never in neither place.
                        let index = self.transcript.land(text: text, start: span.start, end: span.end)
                        let embedding = await self.embedding(for: span)
                        self.transcript.setEmbedding(embedding, at: index)
                    } else {
                        self?.transcript.setVolatile(text: text, start: span.start, end: span.end)
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
            cpuAtStart = ProcessMeter.cpuSeconds()
            rssAtStart = ProcessMeter.residentMB()
            do {
                try engine.start()
            } catch where voiceProcessing {
                // Voice processing failed to start: retry on the raw mic so the take never fails for it.
                // The isolation effect goes with it: the raw input has a different format.
                tapNode?.removeTap(onBus: 0)
                if isolation, let effect = tapNode as? AVAudioUnitEffect { engine.detach(effect) }
                isolation = false
                tapNode = input
                try? input.setVoiceProcessingEnabled(false)
                voiceProcessing = false
                engine.prepare()
                let rawFormat = input.outputFormat(forBus: 0)
                tapChannels = Int(rawFormat.channelCount)
                tapSampleRate = Int(rawFormat.sampleRate)
                input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: onBuffer)
                try engine.start()
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            teardownAudio()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// The speaker embedding of one span, or nil when nothing needs scoring: no voiceprint and no labelled mode
    /// (then the helper is never asked, so an idle or unenrolled app wakes nothing), or the helper cannot answer.
    /// A nil segment inherits a neighbour's label, as a short one does (SpeakerLabeller), so it is kept where that
    /// neighbour is kept. It is kept in every mode only when the take has no labelled neighbour at all.
    private func embedding(for span: (start: Double, end: Double)) async -> [Float]? {
        guard scoresSpeakers else { return nil }
        return try? await FluidSpeakerEmbedder.shared.segmentEmbedding(audio.samples(from: span.start, to: span.end), take: takeID)
    }

    /// Whether this take asks the helper for embeddings: a voiceprint, or the labelled mode.
    private var scoresSpeakers: Bool {
        !voiceprint.isEmpty || Defaults[.dictationSpeakerMode] == .everyoneLabelled
    }

    /// Labels the take's segments for the mode. Without a voiceprint, only the labelled mode labels; the other two
    /// keep everything, as they always have.
    private func labelTake(_ segments: [LabelledSegment]) -> [LabelledSegment] {
        guard !voiceprint.isEmpty || mode == .everyoneLabelled else { return segments }
        return SpeakerLabeller.label(segments, voiceprint: voiceprint, params: .default)
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
            // Nothing from this take may reach the helper after the release below.
            resultsTask.cancel()
        }
        labelled = labelTake(transcript.segments(finalized: finalized))
        await FluidSpeakerEmbedder.shared.release(takeID)
        return [SpeakerLabeller.pasteText(labelled, mode: mode)]
    }

    /// Stops the microphone at key release without waiting for the analyzer. Returns the labelled transcript so far
    /// as one paste (#17 U2b). `finish()` still runs afterwards for the final results.
    func stopNow() async -> [String] {
        teardownAudio()
        mode = Defaults[.dictationSpeakerMode]
        cpuPct = takeCPUPercent()
        rssDeltaMB = ProcessMeter.residentMB() - rssAtStart
        let baseline = rssAtStart
        idleTask = Task {
            try? await Task.sleep(for: .seconds(5))
            return ProcessMeter.residentMB() - baseline
        }
        // The transcript as it stands at release. It is captured before the tail's bounded wait, so a final that lands
        // during the wait is neither lost nor pasted twice, and the tail is the volatile of this moment (#17 U2b).
        if let tail = transcript.release(), scoresSpeakers {
            let samples = audio.samples(from: tail.start, to: tail.end)
            let take = takeID
            let embedding = await TakeTranscript.boundedEmbedding(seconds: 0.3) {
                try? await FluidSpeakerEmbedder.shared.segmentEmbedding(samples, take: take)
            }
            transcript.setTailEmbedding(embedding)
        }
        labelled = labelTake(transcript.releasePaste)
        return [SpeakerLabeller.pasteText(labelled, mode: mode)]
    }

    /// The take's audio as a WAV file, with the segments the mode drops silenced (#17 U2b), or nil when no audio arrived.
    func takeWAV() -> Data? {
        audio.wav(silencing: SpeakerLabeller.droppedRanges(labelled, mode: mode))
    }

    func cancel() async {
        teardownAudio()
        if let analyzer {
            _ = await TimeoutRace.run(seconds: 0.5) { await analyzer.cancelAndFinishNow() }
        }
        if let resultsTask {
            _ = await TimeoutRace.run(seconds: 0.5) { await resultsTask.value }
            // Nothing from this take may reach the helper after the release below.
            resultsTask.cancel()
        }
        transcript = TakeTranscript()
        labelled = []
        await FluidSpeakerEmbedder.shared.release(takeID)
    }

    /// Adds this take's audio and transcript numbers to the report.
    func fill(_ report: inout TakeReport) {
        report.tapChannels = tapChannels
        report.tapSampleRate = tapSampleRate
        report.finals = transcript.finals.count
        report.partials = partialCount
        report.finalizeMs = finalizeMs
        report.voiceProcessing = voiceProcessing
        report.volatileTail = !finalized && transcript.hasVolatile
        if let engineStartedAt, let firstPartialAt {
            report.firstPartialMs = Int((firstPartialAt - engineStartedAt) * 1000)
        }
        levelTap.fill(&report)
        report.speakerGate = !voiceprint.isEmpty
        report.speakerMode = mode
        var distinct: [SpeakerLabel] = []
        for segment in labelled where segment.label != .unknown && !distinct.contains(segment.label) {
            distinct.append(segment.label)
        }
        report.speakers = distinct.count
        report.speakerDropped = labelled.count - SpeakerLabeller.kept(labelled, mode: mode).count
        report.cpuPct = cpuPct
        report.rssDeltaMB = rssDeltaMB
        report.voiceIsolation = isolation
        report.ducking = voiceProcessing ? .mid : .off
        report.level = SpeakerGate.levelDBFS(audio.samples(from: 0, to: 8))
    }

    /// The take's length so far, for the rewrite gate.
    var takeSeconds: Double { audio.seconds }

    /// The 5-second idle sample started at key release, if any. The manager awaits it before the take line is logged.
    func idleSample() -> Task<Int, Never>? {
        idleTask
    }

    /// The take's share of one core since the engine started, in percent. -1 when the engine never started.
    private func takeCPUPercent() -> Double {
        guard let engineStartedAt else { return -1 }
        let wall = ProcessInfo.processInfo.systemUptime - engineStartedAt
        guard wall > 0 else { return -1 }
        return (ProcessMeter.cpuSeconds() - cpuAtStart) / wall * 100
    }

    private func teardownAudio() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        tapNode?.removeTap(onBus: 0)
        engine.stop()
        // Voice processing is switched off on every exit, so the music returns to full volume (#17 U2b).
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        if pausedMedia {
            pausedMedia = false
            MusicManager.shared.play()
        }
        continuation?.finish()
        continuation = nil
    }
}
