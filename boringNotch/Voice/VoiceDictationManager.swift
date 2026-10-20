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

    private var hotkey = DictationHotkeyLogic.State()
    private var session: (any VoiceSession)?
    /// Key released while `begin()` is still awaiting the mic prompt or the analyzer.
    private var stopRequested = false
    private var resetTask: Task<Void, Never>?

    private init() {}

    // MARK: - Hotkey

    func hotkeyDown() {
        handle(.keyDown)
    }

    func hotkeyUp() {
        handle(.keyUp)
    }

    private func handle(_ event: DictationHotkeyLogic.Event) {
        // A new press during the "Pasted" or error flash starts a fresh take.
        if event == .keyDown, isResting {
            resetTask?.cancel()
            state = .idle
            liveText = ""
        }
        guard state == .idle || state == .recording else { return }

        let action = DictationHotkeyLogic.reduce(
            &hotkey, event, at: ProcessInfo.processInfo.systemUptime)
        switch action {
        case .start:
            Task { await begin() }
        case .stop:
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

    private func begin() async {
        guard state == .idle else { return }
        state = .recording
        liveText = ""
        stopRequested = false

        guard #available(macOS 26.0, *) else {
            fail("Needs macOS 26")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail("Microphone access denied")
            return
        }

        let started = SpeechAnalyzerSession()
        do {
            try await started.start { [weak self] partial in
                Task { @MainActor in self?.liveText = partial }
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        // `session` is only set once the engine runs, so finish() can tell a
        // still-starting take (stopRequested) from a live one.
        session = started
        if stopRequested {
            await finish()
        }
    }

    private func finish() async {
        guard state == .recording else { return }
        guard let current = session else {
            stopRequested = true
            return
        }
        state = .processing
        hotkey = DictationHotkeyLogic.State()

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
    private func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        let trusted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
        let change = PasteboardSnapshot.write(text, to: pasteboard)
        guard trusted else {
            // The text stays on the clipboard so nothing is lost.
            fail("Copied. Allow Accessibility to auto-paste")
            return
        }

        await waitForModifiersReleased(timeout: 1.0)
        guard await XPCHelperClient.shared.postPasteKeystroke() else {
            fail("Copied. Paste failed")
            return
        }

        try? await Task.sleep(for: .milliseconds(250))
        snapshot.restore(to: pasteboard, ifChangeCountIs: change)
        state = .done
        scheduleReset(after: 1.2)
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
        session = nil
        hotkey = DictationHotkeyLogic.State()
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
