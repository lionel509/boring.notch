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
    func start(onPartial: @escaping @Sendable (String) -> Void) async throws
    func finish() async throws -> [String]
    func cancel() async
}

@MainActor
final class VoiceDictationManager: ObservableObject {
    static let shared = VoiceDictationManager()

    @Published private(set) var state: VoiceDictationState = .idle
    @Published private(set) var liveText: String = ""
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

    private init() {}

    // MARK: - Hotkey

    func hotkeyDown() {
        handle(.keyDown)
    }

    func hotkeyUp() {
        handle(.keyUp)
    }

    private func handle(_ event: DictationHotkeyLogic.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        // While transcribing, only track the key. The next take starts after the paste.
        guard state != .processing else {
            DictationHotkeyLogic.track(&hotkey, event, at: now)
            return
        }

        let action = DictationHotkeyLogic.reduce(&hotkey, event, at: now)
        switch action {
        case .start:
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
            ceilingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(DictationHotkeyLogic.maxTake))
                guard !Task.isCancelled else { return }
                self?.handle(.timeout)
            }
            Task { await begin(take) }
        case .stop:
            ceilingTask?.cancel()
            Task { await finish() }
        case .none:
            break
        }
    }

    private var isResting: Bool {
        switch state {
        case .done, .failed: return true
        default: return false
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
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard take == takeID else { return }
        guard granted else {
            fail("Microphone access denied")
            return
        }

        let started = SpeechAnalyzerSession()
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
        // `session` is only set once the engine runs, so finish() can tell a
        // still-starting take (stopRequested) from a live one.
        session = started
        startGraceTask?.cancel()
        if stopRequested {
            await finish()
        }
    }

    private func finish() async {
        guard state == .recording else { return }
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

        let parts = (try? await current.finish()) ?? []
        session = nil

        let text = TranscriptAssembler.join(parts)
        guard !text.isEmpty else {
            fail("Nothing heard")
            return
        }
        await insert(text)
    }

    /// Puts the text on the pasteboard, presses Cmd-V in the focused app, then puts
    /// the user's previous clipboard back unless they copied something meanwhile.
    /// On every failure path the transcript stays on the clipboard, replacing what was there.
    private func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let trustedResult = await TimeoutRace.run(seconds: 3) {
            await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
        }
        // Snapshot after the await, so a copy made during it is kept, not overwritten.
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        let change = PasteboardSnapshot.write(text, to: pasteboard)
        guard let trusted = trustedResult else {
            fail("Copied (clipboard replaced). Helper not responding")
            return
        }
        guard trusted else {
            fail("Copied (clipboard replaced). Allow Accessibility to paste")
            return
        }

        await waitForModifiersReleased(timeout: 1.0)
        // Someone copied during the modifier wait: do not paste their copy in place of the transcript.
        guard pasteboard.changeCount == change else {
            fail("Clipboard changed. Not pasted")
            return
        }
        // Read the layout on the main actor, where the TIS calls belong.
        let keyCode = PasteKeycode.currentV()
        let posted = await TimeoutRace.run(seconds: 3) {
            await XPCHelperClient.shared.postPasteKeystroke(keyCode: keyCode)
        }
        guard let posted else {
            fail("Copied (clipboard replaced). Helper slow, paste may still land")
            return
        }
        guard posted else {
            fail("Copied (clipboard replaced). Paste failed")
            return
        }

        state = .done
        scheduleReset(after: 1.2)
        try? await Task.sleep(for: .milliseconds(1000))
        snapshot.restore(to: pasteboard, ifChangeCountIs: change)
    }

    /// Cmd-V with Option still held would paste as Option-Cmd-V in many apps.
    private func waitForModifiersReleased(timeout: TimeInterval) async {
        let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let deadline = Date().addingTimeInterval(timeout)
        while !NSEvent.modifierFlags.intersection(watched).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func fail(_ message: String) {
        ceilingTask?.cancel()
        startGraceTask?.cancel()
        downloadingModel = false
        session = nil
        hotkey.recording = false
        hotkey.handsFree = false
        hotkey.downAt = nil
        state = .failed(message)
        scheduleReset(after: 2.5)
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
