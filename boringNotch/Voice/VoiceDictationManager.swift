//
//  VoiceDictationManager.swift
//  boringNotch
//
//  Push-to-talk dictation: hold the shortcut, speak, let go. The notch shows the
//  state. Apple's on-device transcript is pasted into the focused app at once; with
//  cloud on, the cloud transcript and a cleanup pass then rewrite that text in place.
//  Audio and transcript text leave the Mac only through OpenRouterClient, and only
//  when the cloud setting is on.
//

import AppKit
import ApplicationServices
import AVFoundation
import Defaults
import Foundation

enum VoiceDictationState: Equatable {
    case idle
    case recording
    case processing
    case done
    case failed(String)
}

/// One dictation take. The engine (SpeechAnalyzerSession) implements it; the
/// manager only drives it, so the state machine stays testable.
protocol VoiceSession: AnyObject {
    var levelTap: MicLevelTap { get }
    func start(contextualStrings: [String], onPartial: @escaping @Sendable (String) -> Void) async throws
    /// Stops the microphone now and returns the transcript so far.
    func stopNow() -> [String]
    /// The take's audio as a WAV file, or nil when no audio arrived.
    func takeWAV() -> Data?
    func finish() async throws -> [String]
    func cancel() async
    func fill(_ report: inout TakeReport)
}

@MainActor
final class VoiceDictationManager: ObservableObject {
    static let shared = VoiceDictationManager()

    @Published private(set) var state: VoiceDictationState = .idle
    /// The partial transcript. No longer written: the notch shows bars only.
    private(set) var liveText: String = ""
    /// True while the OS installs the speech model on first use.
    @Published private(set) var downloadingModel = false
    /// True from the raw paste until the rewrite ends. The notch shows the bars with a shimmer.
    @Published var refining = false
    /// True when the last key read found no OpenRouter key. Settings shows the hint.
    @Published private(set) var cloudKeyMissing = false

    private var hotkey = DictationHotkeyLogic.State()
    private var session: (any VoiceSession)?
    /// Key released while `begin()` is still awaiting the mic prompt or the analyzer.
    private var stopRequested = false
    private var resetTask: Task<Void, Never>?
    /// Ends the take after `DictationHotkeyLogic.maxTake` seconds.
    private var ceilingTask: Task<Void, Never>?
    /// Identifies the current take, so a `begin()` from an earlier take discards itself.
    private var takeID = 0
    /// Ends a stopped take that never got its engine running within `startGrace` seconds.
    private var startGraceTask: Task<Void, Never>?
    private static let startGrace: Double = 10
    /// Owns the pending clipboard restore across overlapping takes.
    private var clipboard = ClipboardKeeper()
    private var clipboardRestoreTask: Task<Void, Never>?
    /// The numbers for the take in progress. Logged once, when the take ends.
    private var report = TakeReport()
    private var takeOpen = false
    /// Uptime when the take started and when its key was released, for the timing numbers.
    private var takeStartedAt: TimeInterval?
    private var releaseAt: TimeInterval?
    /// The mic meter of the take in progress, set once its engine is created.
    private(set) var levelTap: MicLevelTap?
    /// Live state of the mic for the notch, refreshed while the take records.
    @Published private(set) var micStatus: MicStatus = .waiting
    private var statusTask: Task<Void, Never>?
    /// Uptime when the engine started, so the mic is judged only after it has had time to deliver.
    private var engineStartedAt: TimeInterval?
    /// Read at key press, so the release does not wait on the helper. Memory only; never stored.
    private var cachedKey: String?
    /// Accessibility trust read at key press. Nil when that read has not returned yet.
    private var trustedAtStart: Bool?
    /// The app the take started in, and the register and dictionary taken from it.
    private var takeBundleID: String?
    private var takeTone: AppTone = .neutral
    private var takeDictionary: [String] = []
    /// The rewrite of the take whose text is in the field, while it runs.
    private var rewriter: TakeRewriter?
    /// Learns words the user corrects after a paste. Cancelled by the next press.
    private var learnTask: Task<Void, Never>?

    private init() {}

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func elapsedMs(since start: TimeInterval) -> Int {
        Int((now - start) * 1000)
    }

    // MARK: - Hotkey

    func hotkeyDown() {
        handle(.keyDown)
    }

    func hotkeyUp() {
        handle(.keyUp)
    }

    /// Entry point for the fn-key tap (`FnKeyMonitor`). Named apart from the `hotkey` state property.
    /// `time` is the event's own time, so a late dispatch does not change how long the key was held.
    func fnKey(_ event: DictationHotkeyLogic.Event, at time: TimeInterval) {
        handle(event, at: time)
    }

    private func handle(_ event: DictationHotkeyLogic.Event, at time: TimeInterval? = nil) {
        let now = time ?? ProcessInfo.processInfo.systemUptime
        // While transcribing, only track the key. A rewrite still running does not block a new take.
        guard !(state == .processing && rewriter == nil) else {
            DictationHotkeyLogic.track(&hotkey, event, at: now)
            return
        }

        let action = DictationHotkeyLogic.reduce(&hotkey, event, at: now)
        switch action {
        case .start:
            // A rewrite still running is cut here: its last whole target stays in the field, and its take is logged.
            if let old = rewriter {
                old.cancel()
                closeRewrite(old)
            }
            DictationSounds.playStart()
            // A take still open here was superseded before it ended. Log it so every take has one line.
            endTake(.discarded)
            // Cancel the stored engine of a superseded take. One still inside analyzer.start is torn down when start returns (begin).
            if let old = session {
                session = nil
                Task { await old.cancel() }
            }
            takeID += 1
            let take = takeID
            ceilingTask?.cancel()
            startGraceTask?.cancel()
            downloadingModel = false
            // A new press during the "Pasted" or error flash starts a fresh take.
            resetTask?.cancel()
            learnTask?.cancel()
            state = .recording
            stopRequested = false
            report = TakeReport()
            releaseAt = nil
            takeStartedAt = now
            takeOpen = true
            engineStartedAt = nil
            trustedAtStart = nil
            startStatusPolling(take)
            takeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            takeTone = AppTone.forBundle(takeBundleID)
            takeDictionary = PersonalDictionary.words(
                manual: Defaults[.dictationDictionary], learned: Defaults[.dictationLearnedWords]
            )
            report.tone = takeTone
            report.dictionaryWords = takeDictionary.count
            report.cloud = Defaults[.dictationCloud]
            // Both reads run while the user is still holding the key, so the release does not wait on them.
            Task { [weak self] in
                let trusted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                self?.trustedAtStart = trusted
            }
            if Defaults[.dictationCloud] {
                Task { [weak self] in
                    let key = await XPCHelperClient.shared.openRouterKey()
                    self?.cachedKey = key
                    self?.cloudKeyMissing = key == nil
                }
            }
            ceilingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(DictationHotkeyLogic.maxTake))
                guard !Task.isCancelled else { return }
                self?.handle(.timeout)
            }
            Task { await begin(take) }
        case .stop:
            DictationSounds.playStop()
            releaseAt = now
            if let started = takeStartedAt {
                report.holdMs = Int((now - started) * 1000)
            }
            ceilingTask?.cancel()
            // Stop now, not in a queued Task: a press handled before that Task would see
            // the take still recording and could be stopped or pasted into the wrong take.
            stop(takeID)
        case .discard:
            discard()
        case .none:
            break
        }
    }

    /// fn was a modifier, or a quick fn tap: stop the mic and drop the take. Nothing is
    /// pasted and the clipboard is not touched.
    private func discard() {
        takeID += 1
        ceilingTask?.cancel()
        startGraceTask?.cancel()
        resetTask?.cancel()
        statusTask?.cancel()
        stopRequested = false
        downloadingModel = false
        if let captured = session {
            session = nil
            Task { await captured.cancel() }
        }
        if let running = rewriter {
            running.cancel()
            closeRewrite(running)
        }
        state = .idle
        hotkey.startedAt = nil
        endTake(.discarded)
    }

    /// Logs the take's report once, when the take ends with `outcome`, and drops its meter.
    private func endTake(_ outcome: TakeOutcome) {
        levelTap = nil
        guard takeOpen else { return }
        takeOpen = false
        report.outcome = outcome
        DictationLog.take(report)
    }

    /// Ends a rewrite: its numbers go into the take report and the take is logged. Only the rewrite that is
    /// still current closes. A superseded one was already closed by the press that replaced it.
    private func closeRewrite(_ running: TakeRewriter) {
        guard rewriter === running else { return }
        rewriter = nil
        refining = false
        running.fill(&report)
        endTake(.pasted)
    }

    private var isResting: Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }

    /// Refreshes `micStatus` every 250 ms while this take records. Assigns only on change.
    private func startStatusPolling(_ take: Int) {
        statusTask?.cancel()
        micStatus = .waiting
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, take == self.takeID, self.state == .recording else { return }
                let next: MicStatus
                if self.session != nil, let tap = self.levelTap, let started = self.engineStartedAt {
                    next = tap.status(elapsed: self.now - started)
                } else {
                    next = .waiting
                }
                if next != self.micStatus { self.micStatus = next }
            }
        }
    }

    // MARK: - Take lifecycle

    /// Every `await` below is followed by a `take == takeID` check: a superseded or
    /// timed-out take must not write UI state, open a second engine, or call `fail`.
    private func begin(_ take: Int) async {
        guard #available(macOS 26.0, *) else {
            fail("Needs macOS 26")
            return
        }
        guard take == takeID else { return }
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        report.authStatus = authorization.rawValue
        guard authorization != .denied, authorization != .restricted else {
            fail("Mic access off. See Settings", outcome: .accessDenied)
            return
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard take == takeID else { return }
        report.granted = granted
        guard granted else {
            fail("Mic access off. See Settings", outcome: .accessDenied)
            return
        }

        let started = SpeechAnalyzerSession()
        levelTap = started.levelTap
        do {
            try await started.prepareModel { [weak self] in
                guard let self, take == self.takeID else { return }
                self.downloadingModel = true
            }
            guard take == takeID else { return }
            downloadingModel = false
            try await started.start(contextualStrings: takeDictionary) { _ in }
        } catch {
            guard take == takeID else { return }
            downloadingModel = false
            fail(error.localizedDescription)
            return
        }
        // The engine has started. If this take was superseded meanwhile, stop it here
        // so no second microphone session is left running.
        guard take == takeID else {
            await started.cancel()
            return
        }
        // `session` is only set once the engine runs, so stop() can tell a
        // still-starting take (stopRequested) from a live one.
        session = started
        engineStartedAt = now
        report.engineStartMs = takeStartedAt.map { elapsedMs(since: $0) } ?? -1
        startGraceTask?.cancel()
        if stopRequested {
            stop(take)
        }
    }

    /// Ends the take at key release. Not async: `state` is `.processing` before this returns,
    /// so a key event handled before any queued Task runs is only tracked. `complete` does the rest.
    private func stop(_ take: Int) {
        guard take == takeID, state == .recording else { return }
        guard let current = session else {
            stopRequested = true
            // If the engine never starts, end the take instead of leaving "Recording" up.
            startGraceTask?.cancel()
            let take = takeID
            startGraceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.startGrace))
                guard !Task.isCancelled, let self, take == self.takeID,
                      self.session == nil, self.state == .recording else { return }
                let message = self.downloadingModel
                    ? "Model still downloading. Try again"
                    : "Speech engine did not start. Try again"
                // Bumping the take makes a still-pending begin() discard itself.
                self.takeID += 1
                self.fail(message)
            }
            return
        }
        state = .processing
        statusTask?.cancel()
        Task { await complete(current) }
    }

    /// Releases the mic, then pastes the raw transcript at once and rewrites it in place.
    private func complete(_ current: any VoiceSession) async {
        let rawNow = TranscriptAssembler.join(current.stopNow())
        let wav = current.takeWAV()
        // Apple's final results: they land after the paste and only matter for the rewrite and the empty take.
        let finalTask = Task { (try? await current.finish()) ?? [] }
        let verdict = levelTap?.meter.verdict ?? .noBuffers
        session = nil
        // A take with real signal proves the mic works, so the warning clears.
        if verdict == .signal { Defaults[.dictationMicSilent] = false }
        await insertAndRefine(rawNow: rawNow, wav: wav, finalTask: finalTask, engine: current, verdict: verdict)
    }

    /// Pastes the raw text, then rewrites it in place when the take allows it. A take with no raw text waits for
    /// the first non-empty of the cloud transcript and Apple's final, and that text is pasted instead.
    private func insertAndRefine(
        rawNow: String, wav: Data?, finalTask: Task<[String], Never>, engine: any VoiceSession, verdict: MicVerdict
    ) async {
        let take = takeID
        let field = await XPCHelperClient.shared.beginTracking()
        let mechanism = field.map { RewriteMechanism.choose(field: $0) } ?? .none
        // The one place the cloud client is built: only with the setting on and the key read at the press.
        let client: OpenRouterClient?
        if Defaults[.dictationCloud], let key = cachedKey {
            client = OpenRouterClient(key: key)
        } else {
            client = nil
        }
        // Secure fields and fields the helper cannot track get the raw paste and nothing else.
        let rewriteWanted = field != nil && mechanism != .none && (client != nil || Defaults[.dictationCleanup])
        let dictionary = takeDictionary
        let tone = takeTone
        let prompt = CloudConfig.vocabularyPrompt(dictionary)

        // Started at release, so the cloud transcript runs while the raw text is pasted.
        let sttTask: Task<TakeRewriter.SttAttempt?, Never> = Task {
            guard rewriteWanted, let client, let wav else { return nil }
            return await VoiceDictationManager.cloudTranscript(client: client, wav: wav, prompt: prompt)
        }
        defer { sttTask.cancel() }

        var text = rawNow
        if text.isEmpty {
            if let attempt = await sttTask.value, !RewritePlanner.normalize(attempt.text).isEmpty {
                text = RewritePlanner.normalize(attempt.text)
            } else {
                text = RewritePlanner.normalize(TranscriptAssembler.join(await finalTask.value))
            }
            guard !text.isEmpty else {
                engine.fill(&report)
                switch verdict {
                case .noBuffers:
                    fail("No audio from the mic", outcome: .noAudio)
                case .digitalSilence:
                    // The mic opened but only zeros arrived: the stale-grant case.
                    Defaults[.dictationMicSilent] = true
                    fail("Mic blocked. See Settings", outcome: .micSilent)
                case .signal:
                    fail("Nothing heard", outcome: .nothingHeard)
                }
                return
            }
        }

        guard await insert(text) else { return }
        guard take == takeID else {
            // A new press arrived during the paste; that press already owns the report.
            return
        }

        guard rewriteWanted, let field else {
            _ = await finalTask.value
            guard take == takeID else { return }
            engine.fill(&report)
            endTake(.pasted)
            if mechanism != .none { scheduleLearning(final: text, bundle: takeBundleID) }
            state = .done
            scheduleReset(after: 0.6)
            return
        }

        // Without a readable caret the rewrite needs key events to abort on user input. With neither the
        // caret nor a key abort, the rewrite could overwrite text the user typed, so the Stage-A text stays.
        let keyAbortLive = FnKeyMonitor.shared.isTapLive || (AXIsProcessTrusted() && CGPreflightListenEventAccess())
        guard RewriteMechanism.effective(mechanism, caretReadable: field.caret >= 0, keyAbortLive: keyAbortLive) != nil else {
            engine.fill(&report)
            report.rewrite = .noAbortSource
            endTake(.pasted)
            if mechanism != .none { scheduleLearning(final: text, bundle: takeBundleID) }
            state = .done
            scheduleReset(after: 0.6)
            return
        }

        let running = TakeRewriter(
            committed: text, field: field, mechanism: mechanism, keyAbortLive: keyAbortLive, releaseAt: releaseAt ?? now)
        rewriter = running
        refining = true
        await running.run(
            stt: { await sttTask.value },
            appleFinal: { TranscriptAssembler.join(await finalTask.value) },
            stream: { input in
                guard let client else { return nil }
                return client.streamCleanup(
                    model: CloudConfig.cleanupModels[0],
                    system: CleanupPrompt.instructions(tone: tone, dictionary: dictionary),
                    user: CleanupPrompt.userMessage(input),
                    maxTokens: max(64, input.split(whereSeparator: { $0.isWhitespace }).count * 3),
                    timeout: CloudConfig.rewriteDeadline
                )
            },
            foundation: { input in
                guard Defaults[.dictationCleanup] else { return nil }
                return await VoiceDictationManager.onDeviceCleanup(input, tone: tone, dictionary: dictionary)
            }
        )

        // A press that superseded this rewrite already closed it, and the new take owns the state now.
        guard rewriter === running else { return }
        _ = await finalTask.value
        engine.fill(&report)
        let finalText = running.committedText
        closeRewrite(running)
        if mechanism != .none { scheduleLearning(final: finalText, bundle: takeBundleID) }
        state = .done
        scheduleReset(after: 0.6)
    }

    /// Tries the cloud transcription models in order. A timeout, a zero-retention block or an HTTP error moves
    /// to the next model. The error text is never logged.
    private static func cloudTranscript(client: OpenRouterClient, wav: Data, prompt: String?) async -> TakeRewriter.SttAttempt? {
        for model in CloudConfig.sttModels {
            guard !Task.isCancelled else { return nil }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let transcript = try await client.transcribe(wav: wav, model: model, prompt: prompt, timeout: CloudConfig.sttTimeout)
                let source: SttSource = model.hasPrefix("assemblyai/") ? .assemblyai
                    : (model.hasPrefix("mistralai/") ? .voxtral : .none)
                return TakeRewriter.SttAttempt(
                    text: transcript.text,
                    source: source,
                    ms: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                    seconds: transcript.seconds,
                    costUSD: transcript.costUSD
                )
            } catch {
                continue
            }
        }
        return nil
    }

    /// On-device cleanup (Apple Intelligence) for when the cloud is off or fails. Nil leaves the text as it is.
    private static func onDeviceCleanup(_ text: String, tone: AppTone, dictionary: [String]) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        guard let cleanup = TranscriptCleanup(instructions: CleanupPrompt.instructions(tone: tone, dictionary: dictionary)) else {
            return nil
        }
        if case .cleaned(let cleaned) = await cleanup.clean(text, budget: CloudConfig.foundationBudget) {
            return cleaned
        }
        return nil
    }

    /// Puts the text on the pasteboard and presses Cmd-V in the focused app. The user's previous clipboard is
    /// put back one second later, unless they copied something meanwhile. Returns false when the take already
    /// failed. On every failure path the transcript stays on the clipboard, replacing what was there.
    /// A take that starts during an earlier take's restore wait inherits that take's saved clipboard, so the user's own clipboard is what comes back.
    private func insert(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let axStart = now
        let trustedResult: Bool?
        if let trustedAtStart {
            trustedResult = trustedAtStart
        } else {
            trustedResult = await TimeoutRace.run(seconds: 3) {
                await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
            }
        }
        report.axMs = elapsedMs(since: axStart)
        // Snapshot after the await, so a copy made during it is kept, not overwritten.
        let change = clipboard.write(text, to: pasteboard)
        guard let trusted = trustedResult else {
            clipboard.release(change)
            fail("Copied (clipboard replaced). Helper not responding")
            return false
        }
        guard trusted else {
            clipboard.release(change)
            fail("Copied (clipboard replaced). Allow Accessibility to paste")
            return false
        }

        let modStart = now
        await waitForModifiersReleased(timeout: 1.0)
        report.modWaitMs = elapsedMs(since: modStart)
        // Someone copied during the modifier wait: do not paste their copy in place of the transcript.
        guard pasteboard.changeCount == change else {
            clipboard.release(change)
            fail("Clipboard changed. Not pasted")
            return false
        }
        // Read the layout on the main actor, where the TIS calls belong.
        let keyCode = PasteKeycode.currentV()
        let pasteStart = now
        let posted = await TimeoutRace.run(seconds: 3) {
            await XPCHelperClient.shared.postPasteKeystroke(keyCode: keyCode)
        }
        report.pasteMs = elapsedMs(since: pasteStart)
        guard let posted else {
            clipboard.release(change)
            fail("Copied (clipboard replaced). Helper slow, paste may still land")
            return false
        }
        guard posted else {
            clipboard.release(change)
            fail("Copied (clipboard replaced). Paste failed")
            return false
        }

        if let released = releaseAt {
            report.releaseToPasteMs = Int((now - released) * 1000)
        }
        // The restore starts at the paste, not at the end of the rewrite: swaps never touch the clipboard.
        clipboardRestoreTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            self?.clipboard.restore(to: pasteboard, ifChangeCountIs: change)
        }
        return true
    }

    /// Cmd-V with Option still held would paste as Option-Cmd-V in many apps.
    private func waitForModifiersReleased(timeout: TimeInterval) async {
        let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let deadline = Date().addingTimeInterval(timeout)
        while !NSEvent.modifierFlags.intersection(watched).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Learns the words the user corrects after a paste, 8 s later, in the same app and only while idle.
    private func scheduleLearning(final text: String, bundle: String?) {
        guard Defaults[.dictationLearnsCorrections] else { return }
        learnTask?.cancel()
        learnTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.state == .idle,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { return }
            let current = await XPCHelperClient.shared.focusedTextValue() ?? ""
            // The alignment is quadratic in the take and the field, so it runs off the main actor.
            let found = await Task.detached(priority: .utility) {
                CorrectionLearner.candidates(pasted: text, current: current)
            }.value
            guard !found.isEmpty else { return }
            var learned = Defaults[.dictationLearnedWords]
            PersonalDictionary.learn(found, into: &learned)
            Defaults[.dictationLearnedWords] = learned
        }
    }

    private func fail(_ message: String, outcome: TakeOutcome = .failed) {
        ceilingTask?.cancel()
        startGraceTask?.cancel()
        statusTask?.cancel()
        downloadingModel = false
        session = nil
        if let running = rewriter {
            running.cancel()
            closeRewrite(running)
        }
        hotkey.recording = false
        hotkey.handsFree = false
        hotkey.downAt = nil
        hotkey.startedAt = nil
        endTake(outcome)
        state = .failed(message)
        scheduleReset(after: 2.0)
    }

    private func scheduleReset(after seconds: Double) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.isResting {
                self.state = .idle
            }
        }
    }
}
