//
//  CallDetector.swift
//  boringNotch
//
//  Asks once when a call app starts using the microphone, and turns fn+Y / fn+N / fn+D into an answer.
//

import Combine
import Defaults
import Foundation

/// Where a transcribed call goes. #17 replaces `StubCallTranscriber` with the real capture.
@MainActor
protocol CallTranscriber: AnyObject {
    /// Yes was answered, or a yes'd call took the mic back within `CallPromptLogic.endGrace`.
    func begin(_ call: DetectedCall)
    /// The call's process released the mic.
    func end(_ call: DetectedCall)
}

/// Records nothing. It shows a short notice, so the answer is visible end to end. Logging stays out of
/// `Voice/`: LogPrivacyTests allows only `DictationLog` to write to the log.
@MainActor
final class StubCallTranscriber: CallTranscriber {
    func begin(_ call: DetectedCall) {
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .dictation, duration: 2, icon: "waveform",
            detail: "stub, #17 plugs in here", label: "Transcribe \(call.name)")
    }

    func end(_ call: DetectedCall) {}
}

/// Watches who holds the microphone and runs `CallPromptLogic` over it.
///
/// Nothing here polls. It is a Combine sink on `DictationManager.micClients`, which the existing
/// CoreAudio listeners publish. The only sleep is the prompt's timeout, and only while a prompt is up.
@MainActor
final class CallDetector: ObservableObject {
    static let shared = CallDetector()

    /// The transcriber receives `begin` and `end`. Replaced by #17's labelled mode.
    var transcriber: CallTranscriber = StubCallTranscriber()

    /// The call the notch is asking about, if any. Arms the fn+Y/N/D keys while set.
    @Published private(set) var pending: DetectedCall? {
        didSet { FnKeyMonitor.shared.callPromptArmed = pending != nil }
    }

    private var state = CallPromptLogic.State()
    private var sink: AnyCancellable?
    /// Re-renders the hint while a prompt is up, so it follows the live fn mode.
    private var modeSink: AnyCancellable?
    private var timeoutTask: Task<Void, Never>?
    /// Bumped on every change to the mic list, so a slow browser lookup cannot apply a stale list.
    private var generation = 0
    private var resolvedPids: Set<Int32> = []
    private var browserCalls: [Int32: DetectedCall] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard sink == nil else { return }
        DictationManager.shared.start()
        sink = DictationManager.shared.$micClients
            .removeDuplicates()
            .sink { [weak self] clients in self?.micClientsChanged(clients) }
        modeSink = FnKeyMonitor.shared.$mode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.renderPendingPrompt() }
    }

    func stop() {
        sink?.cancel()
        sink = nil
        modeSink?.cancel()
        modeSink = nil
        generation &+= 1
        var effects: [CallPromptLogic.Effect] = []
        if let shown = pending { effects.append(.hide(shown)) }
        for id in state.liveOrder where state.transcribing.contains(id) {
            if let call = state.live[id] { effects.append(.end(call)) }
        }
        perform(effects)
        state = CallPromptLogic.State()
        resolvedPids = []
        browserCalls = [:]
    }

    /// fn+Y, fn+N or fn+D, forwarded from `FnKeyMonitor`.
    func answer(_ a: CallAnswer) {
        perform(CallPromptLogic.answer(&state, a, muted: Set(Defaults[.callPromptMuted]), at: now))
    }

    // MARK: - Mic list

    private func micClientsChanged(_ clients: [MicClient]) {
        guard Defaults[.detectCalls] else { return }
        generation &+= 1

        let livePids = Set(clients.map(\.pid))
        resolvedPids.formIntersection(livePids)
        browserCalls = browserCalls.filter { livePids.contains($0.key) }

        // A browser is a call only when one of its window titles names a call service. The titles are
        // read here, matched, and dropped. They are never stored, logged or published.
        let unresolved = clients.filter {
            CallApps.nativeCall(for: $0) == nil && CallApps.isBrowser($0.bundleID) && !resolvedPids.contains($0.pid)
        }
        guard !unresolved.isEmpty else {
            apply(clients)
            return
        }

        let gen = generation
        Task { @MainActor in
            for client in unresolved {
                let titles = await XPCHelperClient.shared.windowTitles(pid: Int(client.pid)) ?? []
                // A lookup that finished after a newer mic change must not write its pid back into the caches.
                guard gen == self.generation else { return }
                self.resolvedPids.insert(client.pid)
                if let call = CallApps.browserCall(titles: titles, pid: client.pid) {
                    self.browserCalls[client.pid] = call
                }
            }
            guard gen == self.generation else { return }
            self.apply(clients)
        }
    }

    private func apply(_ clients: [MicClient]) {
        let calls = clients.compactMap { CallApps.nativeCall(for: $0) ?? browserCalls[$0.pid] }
        perform(CallPromptLogic.update(&state, calls: calls, muted: Set(Defaults[.callPromptMuted]), at: now))
    }

    // MARK: - Effects

    private func perform(_ effects: [CallPromptLogic.Effect]) {
        for effect in effects {
            switch effect {
            case .show(let call):
                if Defaults[.dictateWithFn] {
                    // Always show the prompt when fn dictation is on. Without the fn tap the keys cannot answer, so
                    // the hint is left out, and renderPendingPrompt adds it when the mode goes active. The prompt
                    // times out like any other unanswered prompt. It is never dropped silently.
                    pending = call
                    renderPendingPrompt()
                    restartTimeout(for: call.id)
                } else {
                    // Fn dictation is off in Settings, so there is nothing a yes can start. Count it as unanswered
                    // and do not mute it.
                    perform(CallPromptLogic.timeout(&state, callID: call.id, muted: Set(Defaults[.callPromptMuted]), at: now))
                }

            case .hide:
                pending = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                BoringViewCoordinator.shared.dismissAnnouncement(type: .callPrompt)

            case .begin(let call):
                transcriber.begin(call)

            case .end(let call):
                transcriber.end(call)

            case .mute(let id):
                var muted = Defaults[.callPromptMuted]
                if !muted.contains(id) {
                    muted.append(id)
                    Defaults[.callPromptMuted] = muted
                }
                BoringViewCoordinator.shared.toggleSneakPeek(
                    status: true, type: .dictation, duration: 2, icon: "bell.slash",
                    label: "Won't ask for \(CallApps.displayName(for: id)) again")
            }
        }
    }

    /// Draws the pending prompt. The fn+Y/N/D hint is included only while the fn tap is `.active`, and this runs again
    /// on every fn mode change while a prompt is up, so the hint and the live keys always agree.
    private func renderPendingPrompt() {
        guard let call = pending else { return }
        let keysWork = FnKeyMonitor.shared.mode == .active
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .callPrompt, duration: CallPromptLogic.promptTimeout,
            icon: "phone.fill", detail: keysWork ? "fn+Y transcribe · fn+N no · fn+D never" : "",
            label: "Call detected: \(call.name)")
    }

    /// Times out the prompt for `callID` after `promptTimeout`. Cancelled by any answer or hide.
    private func restartTimeout(for callID: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(CallPromptLogic.promptTimeout))
            guard !Task.isCancelled, let self else { return }
            self.perform(CallPromptLogic.timeout(
                &self.state, callID: callID, muted: Set(Defaults[.callPromptMuted]), at: self.now))
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
