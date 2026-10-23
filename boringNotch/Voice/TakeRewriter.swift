//
//  TakeRewriter.swift
//  boringNotch
//
//  Rewrites one take's pasted text in place. Stage A swaps Apple's paste for the cloud transcript as soon as
//  it arrives; Stage B streams the cleanup LLM over it, sentence by sentence (or word by word where AX allows).
//  `RewriteReducer` decides every step; this class performs its effects through the helper and stops on any
//  sign that the user is typing or clicking in the field.
//

import AppKit
import Foundation

@MainActor
final class TakeRewriter {
    /// One cloud transcript attempt with the numbers the report needs.
    struct SttAttempt: Sendable {
        let text: String
        let source: SttSource
        let ms: Int
        let seconds: Double
        let costUSD: Double
    }

    typealias CleanupStream = AsyncThrowingStream<OpenRouterClient.CleanupEvent, Error>

    private let field: FocusedField
    private let mechanism: RewriteMechanism
    private let releaseAt: TimeInterval
    /// UTF-16 offset where the pasted text starts. Every swap is relative to it.
    private let spanStart: Int
    private(set) var state: RewriteState
    private var align = AlignState()
    private var openStream: ((String) -> CleanupStream?)?
    private var foundation: ((String) async -> String?)?
    private var streamTask: Task<Void, Never>?
    private var firstTokenWatch: Task<Void, Never>?
    private var monitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var lastSentenceCount = 0
    private var lastSwapAt: TimeInterval = 0
    private var llmStartedAt: TimeInterval = 0
    private var cleanupSkip: CleanupSkip = .none
    private var swapCount = 0
    private var maxSwapMs = -1
    private var firstCleanupMs = -1
    private var sttMs = -1
    private var sttSeconds: Double = -1
    private var sttCostUSD: Double = -1
    private var llmFirstTokenMs = -1
    private var llmTotalMs = -1
    private var llmPromptTokens = -1
    private var llmCompletionTokens = -1

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// `committed` is the text already pasted at `field.caret`. Without a readable caret the AX mechanisms
    /// need offsets they cannot have, so the take uses key events, which only need the caret at the span end.
    /// `keyAbortLive` says whether key events can abort the rewrite; the caller has already checked that one
    /// of the two holds.
    init(committed: String, field: FocusedField, mechanism: RewriteMechanism, keyAbortLive: Bool,
         releaseAt: TimeInterval) {
        self.field = field
        self.mechanism = RewriteMechanism.effective(
            mechanism, caretReadable: field.caret >= 0, keyAbortLive: keyAbortLive) ?? .keys
        self.spanStart = max(field.caret, 0)
        self.releaseAt = releaseAt
        state = RewriteState(committed: committed)
    }

    /// Drives the take to its end: the reducer finishes, the deadline passes, or the user touches the text.
    /// Always releases the abort monitors and the helper's tracking.
    func run(
        stt: @escaping () async -> SttAttempt?,
        appleFinal: @escaping () async -> String?,
        stream: @escaping (String) -> CleanupStream?,
        foundation: @escaping (String) async -> String?
    ) async {
        openStream = stream
        self.foundation = foundation
        installMonitors()

        let sttTask = Task { [weak self] in
            let attempt = await stt()
            guard let self else { return }
            if let attempt {
                self.sttMs = attempt.ms
                self.sttSeconds = attempt.seconds
                self.sttCostUSD = attempt.costUSD
                await self.apply(.sttArrived(attempt.text, attempt.source))
            } else {
                await self.apply(.sttFailed)
            }
        }
        let appleTask = Task { [weak self] in
            let text = await appleFinal()
            await self?.apply(.appleFinal(text ?? ""))
        }
        let deadlineTask = Task { [weak self] in
            let remaining = (self?.releaseAt ?? 0) + CloudConfig.rewriteDeadline - ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .seconds(max(0, remaining)))
            guard !Task.isCancelled, let self else { return }
            await self.apply(.deadline)
        }

        while state.stage != .ended {
            try? await Task.sleep(for: .milliseconds(20))
        }

        sttTask.cancel()
        appleTask.cancel()
        deadlineTask.cancel()
        streamTask?.cancel()
        firstTokenWatch?.cancel()
        removeMonitors()
        await XPCHelperClient.shared.endTracking()
    }

    /// The user acted, or the take was superseded. No further events are posted; the field keeps its last
    /// whole target. Safe to call more than once.
    func cancel() {
        guard state.stage != .ended else { return }
        _ = RewriteReducer.reduce(&state, .cancelled)
        streamTask?.cancel()
    }

    /// Copies what the rewrite did into the take report.
    func fill(_ report: inout TakeReport) {
        report.sttMs = sttMs
        report.sttSource = state.sttSource
        report.sttSeconds = Float(sttSeconds)
        report.sttCostMicroUSD = sttCostUSD >= 0 ? Int(sttCostUSD * 1_000_000) : -1
        report.firstCleanupMs = firstCleanupMs
        report.llmFirstTokenMs = llmFirstTokenMs
        report.llmTotalMs = llmTotalMs
        report.llmPromptTokens = llmPromptTokens
        report.llmCompletionTokens = llmCompletionTokens
        report.swaps = swapCount
        report.maxSwapMs = maxSwapMs
        report.mechanism = mechanism
        report.rewrite = state.outcome
        report.cleanupSource = state.cleanupSource
        report.cleanupSkip = cleanupSkip
    }

    /// The text the field should now hold once the rewrite ends: the last whole target.
    var committedText: String { state.committed }

    // MARK: - Reducer plumbing

    private func apply(_ event: RewriteEvent) async {
        await send(RewriteReducer.reduce(&state, event))
    }

    private func send(_ effects: [RewriteEffect]) async {
        for effect in effects {
            guard state.stage != .ended else { return }
            switch effect {
            case .swap(let target), .revert(let target):
                let code = await performSwap(to: target)
                await apply(.swapResult(code))
            case .startStream(let input):
                await startStream(input)
            case .startFoundation(let input):
                let text = await foundation?(input)
                await apply(.foundationResult(text))
            case .finish:
                return
            }
        }
    }

    private func startStream(_ input: String) async {
        guard let events = openStream?(input) else {
            cleanupSkip = .unavailable
            await apply(.streamFailed)
            return
        }
        llmStartedAt = now
        streamTask = Task { [weak self] in
            await self?.consume(events, stageA: input)
        }
        // No first token inside the budget: the cleanup falls to the on-device model.
        firstTokenWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CloudConfig.cleanupFirstTokenTimeout))
            guard !Task.isCancelled, let self, self.state.stage == .streaming, !self.state.sawToken else { return }
            self.cleanupSkip = .timeout
            self.streamTask?.cancel()
            await self.apply(.streamFailed)
        }
    }

    // MARK: - Stage B

    private func consume(_ events: CleanupStream, stageA: String) async {
        var cumulative = ""
        do {
            for try await event in events {
                guard state.stage == .streaming else { return }
                switch event {
                case .delta(let piece):
                    if llmFirstTokenMs < 0 { llmFirstTokenMs = elapsedMs(since: llmStartedAt) }
                    cumulative += piece
                    let cleaned = RewritePlanner.normalize(cumulative)
                    await apply(.tokens(cleaned))
                    guard await streamStep(cleaned: cleaned, stageA: stageA) else { return }
                case .usage(let prompt, let completion):
                    llmPromptTokens = prompt
                    llmCompletionTokens = completion
                }
            }
            guard state.stage == .streaming else { return }
            llmTotalMs = elapsedMs(since: llmStartedAt)
            let full = RewritePlanner.normalize(cumulative)
            guard CleanupGuard.accept(raw: stageA, cleaned: full) else {
                cleanupSkip = .guardRejected
                await apply(.streamFailed)
                return
            }
            await apply(.streamEnded)
        } catch {
            guard state.stage == .streaming else { return }
            if cleanupSkip == .none { cleanupSkip = .error }
            await apply(.streamFailed)
        }
    }

    /// Checks each newly completed sentence against the raw words it aligned to, then swaps the span to the
    /// next whole target. Returns false when the stage ended or a sentence was rejected (the span reverts).
    private func streamStep(cleaned: String, stageA: String) async -> Bool {
        let (sentences, _) = SentenceSplitter.completeSentences(in: cleaned, streamEnded: false)
        let fresh = sentences.count > lastSentenceCount
        if fresh {
            for sentence in sentences[lastSentenceCount...] {
                let words = sentence.split(whereSeparator: { $0.isWhitespace }).count
                let window = RewritePlanner.rawWindow(raw: stageA, state: align, sentenceWords: words)
                guard CleanupGuard.acceptSentence(sentence: sentence, rawWindow: window) else {
                    cleanupSkip = .guardRejected
                    await apply(.streamFailed)
                    return false
                }
            }
            lastSentenceCount = sentences.count
        }
        let current = now
        let throttled = current - lastSwapAt >= Double(CloudConfig.swapThrottleMs) / 1000
        // Sentence mechanisms swap only when a sentence completes; the AX mechanism also swaps per word.
        guard fresh || (mechanism == .ax && throttled) else { return true }
        let target = RewritePlanner.target(cleaned: cleaned, streamEnded: false, raw: stageA, state: &align)
        guard target != state.committed else { return true }
        lastSwapAt = current
        state.inFlight = RewriteState.Flight(target: target, kind: .stageA)
        await apply(.swapResult(await performSwap(to: target)))
        return state.stage == .streaming
    }

    // MARK: - The swap

    /// One whole-span replacement through the helper. Returns the helper's code, or 4 when the user moved the
    /// caret or focus, or 5 when the rewrite was cancelled.
    private func performSwap(to target: String) async -> Int {
        guard state.stage != .ended else { return 5 }
        guard let step = RewritePlanner.step(from: state.committed, to: target) else { return 0 }
        if field.caret >= 0 {
            let caret = await XPCHelperClient.shared.caretLocation()
            // -1 is unknown; anything else must be where our last write left the caret.
            if caret != -1, caret != spanStart + state.committed.utf16.count { return 4 }
        }
        guard state.stage != .ended else { return 5 }

        let started = now
        let location = spanStart + step.prefixUTF16
        let code: Int
        switch mechanism {
        case .ax:
            code = await XPCHelperClient.shared.axReplace(location, step.oldMiddle.utf16.count, step.newMiddle)
        case .axSelectType:
            code = await XPCHelperClient.shared.axSelectThenType(
                location, step.oldMiddle.utf16.count, step.newMiddle, caretAfter: spanStart + target.utf16.count
            )
        case .keys, .none:
            code = await XPCHelperClient.shared.typeSwap(
                suffixGraphemes: step.suffixGraphemes, oldGraphemes: step.oldMiddleGraphemes, text: step.newMiddle
            )
        }
        if code == 0 {
            swapCount += 1
            maxSwapMs = max(maxSwapMs, Int((now - started) * 1000))
            if firstCleanupMs < 0 { firstCleanupMs = elapsedMs(since: releaseAt) }
        }
        return code
    }

    // MARK: - Abort sources

    /// Any untagged key or mouse event, the fn tap, a click, a scroll, or an app switch ends the rewrite.
    /// Our own events carry `DictationEvents.tag` and are ignored.
    private func installMonitors() {
        FnKeyMonitor.shared.userInput = { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if let cg = event.cgEvent, DictationEvents.isSynthesized(cg.getIntegerValueField(.eventSourceUserData)) { return }
            Task { @MainActor in self?.cancel() }
        }) {
            monitors.append(monitor)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    private func removeMonitors() {
        FnKeyMonitor.shared.userInput = nil
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
    }

    private func elapsedMs(since start: TimeInterval) -> Int {
        Int((now - start) * 1000)
    }
}
