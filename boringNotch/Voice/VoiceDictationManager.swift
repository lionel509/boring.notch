//
//  VoiceDictationManager.swift
//  boringNotch
//
//  Push-to-talk dictation: hold the shortcut, speak, let go. The notch shows the
//  state, the speech is transcribed on this Mac, and the text is pasted into the
//  focused app. Audio and transcripts never leave the machine.
//

import AppKit
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
    func start(onPartial: @escaping @Sendable (String) -> Void) async throws
    func finish() async throws -> [String]
    func cancel() async
    func fill(_ report: inout TakeReport)
}

@MainActor
final class VoiceDictationManager: ObservableObject {
    static let shared = VoiceDictationManager()

    @Published private(set) var state: VoiceDictationState = .idle
    /// The partial transcript. Kept for the engine callbacks; the notch no longer shows it.
    private(set) var liveText: String = ""
    /// True while the OS installs the speech model on first use.
    @Published private(set) var downloadingModel = false

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
        // While transcribing, only track the key. The next take starts after the paste.
        guard state != .processing else {
            DictationHotkeyLogic.track(&hotkey, event, at: now)
            return
        }

        let action = DictationHotkeyLogic.reduce(&hotkey, event, at: now)
        switch action {
        case .start:
            DictationSounds.playStart()
            // A take still open here was superseded before it ended. Log it so every take has one line.
            endTake(.discarded)
            // Cancel the engine of a superseded take here, so no microphone session is left running.
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
            state = .recording
            liveText = ""
            stopRequested = false
            report = TakeReport()
            releaseAt = nil
            takeStartedAt = now
            takeOpen = true
            engineStartedAt = nil
            startStatusPolling(take)
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
        state = .idle
        liveText = ""
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
            try await started.start { [weak self] partial in
                Task { @MainActor in
                    guard let self, take == self.takeID else { return }
                    self.liveText = partial
                }
            }
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
                    ? "Speech model still downloading. Try again"
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

    /// The slow half of a stop: waits for the engine's last results, then pastes or reports.
    private func complete(_ current: any VoiceSession) async {
        let parts = (try? await current.finish()) ?? []
        current.fill(&report)
        let verdict = levelTap?.meter.verdict ?? .noBuffers
        session = nil
        // A take with real signal proves the mic works, so the warning clears.
        if verdict == .signal { Defaults[.dictationMicSilent] = false }

        let text = TranscriptAssembler.join(parts)
        guard !text.isEmpty else {
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
        await insert(text)
    }

    /// Puts the text on the pasteboard, presses Cmd-V in the focused app, then puts
    /// the user's previous clipboard back unless they copied something meanwhile.
    /// On every failure path the transcript stays on the clipboard, replacing what was there.
    /// A take that starts during an earlier take's restore wait inherits that take's saved clipboard, so the user's own clipboard is what comes back.
    private func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let axStart = now
        let trustedResult = await TimeoutRace.run(seconds: 3) {
            await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
        }
        report.axMs = elapsedMs(since: axStart)
        // Snapshot after the await, so a copy made during it is kept, not overwritten.
        let change = clipboard.write(text, to: pasteboard)
        guard let trusted = trustedResult else {
            clipboard.release(change)
            fail("Copied (clipboard replaced). Helper not responding")
            return
        }
        guard trusted else {
            clipboard.release(change)
            fail("Copied (clipboard replaced). Allow Accessibility to paste")
            return
        }

        let modStart = now
        await waitForModifiersReleased(timeout: 1.0)
        report.modWaitMs = elapsedMs(since: modStart)
        // Someone copied during the modifier wait: do not paste their copy in place of the transcript.
        guard pasteboard.changeCount == change else {
            clipboard.release(change)
            fail("Clipboard changed. Not pasted")
            return
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
            return
        }
        guard posted else {
            clipboard.release(change)
            fail("Copied (clipboard replaced). Paste failed")
            return
        }

        if let released = releaseAt {
            report.releaseToPasteMs = Int((now - released) * 1000)
        }
        endTake(.pasted)
        state = .done
        scheduleReset(after: 0.6)
        try? await Task.sleep(for: .milliseconds(1000))
        clipboard.restore(to: pasteboard, ifChangeCountIs: change)
    }

    /// Cmd-V with Option still held would paste as Option-Cmd-V in many apps.
    private func waitForModifiersReleased(timeout: TimeInterval) async {
        let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let deadline = Date().addingTimeInterval(timeout)
        while !NSEvent.modifierFlags.intersection(watched).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fail(_ message: String, outcome: TakeOutcome = .failed) {
        ceilingTask?.cancel()
        startGraceTask?.cancel()
        statusTask?.cancel()
        downloadingModel = false
        session = nil
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
                self.liveText = ""
            }
        }
    }
}
