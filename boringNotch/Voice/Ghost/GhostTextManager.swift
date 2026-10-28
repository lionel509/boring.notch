//
//  GhostTextManager.swift
//  boringNotch
//

import AppKit
import ApplicationServices
import Defaults
import SwiftUI

/// Owns the key and mouse tap for ghost text. Decisions live in `GhostTextLogic` and `GhostTextGeometry`;
/// this class creates the tap, runs the pause timer and the helper and model calls, and carries out effects.
/// Counting and logging go through `GhostTextLog`.
@MainActor
final class GhostTextManager: ObservableObject {
    static let shared = GhostTextManager()

    enum Mode: Equatable {
        case off
        case active
        case denied
        case unavailable
    }

    @Published private(set) var mode: Mode = .off

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?
    private var machine = GhostTextLogic.Machine()
    private var timerTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    /// Where the current suggestion goes. Set just before the suggestion is handed to the machine.
    private var anchor: GhostTextLogic.Anchor?
    private var pendingCaret: CGRect?
    private var pendingField: CGRect?
    private var pendingFontName: String?
    private var pendingFontSize: Double?
    /// When he last typed, read at the pause so `shown` can carry the latency.
    private var lastTypedAt: TimeInterval?
    /// Set while showOverlay hides the overlay itself through focusChanged. That hide is not a user dismissal, so it logs nothing.
    private var overlayHide = false

    private init() {}

    func start() {
        guard tap == nil, Defaults[.ghostText] else { return }
        guard #available(macOS 26.0, *), GhostTextModel.shared.isAvailable else {
            mode = .unavailable
            return
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Default tap only: a passive tap cannot swallow the accept key, so focus would move and
        // the insert would land in the wrong field. No fallback on purpose.
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: ghostTapCallback,
            userInfo: userInfo
        ) else {
            mode = .denied
            return
        }

        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handle(.focusChanged) }
        }
        mode = .active
    }

    func stop() {
        handle(.stop)
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        timerTask?.cancel()
        fetchTask?.cancel()
        mode = .off
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - Tap

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Keys typed while the tap was off were never seen, so the state must reset too.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            handle(.tapReset)
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            handle(.focusChanged)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let key = GhostTextLogic.decide(Self.keyEvent(from: event), suggestionVisible: machine.isShowing)
            let effects = handle(.key(key))
            return effects.contains(.swallow) ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Reads the raw event into the plain value `GhostTextLogic.decide` classifies. No modifier test happens here.
    private static func keyEvent(from event: CGEvent) -> GhostTextLogic.KeyEvent {
        var buffer = [UniChar](repeating: 0, count: 4)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return GhostTextLogic.KeyEvent(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags.rawValue,
            isKeyDown: event.type == .keyDown,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isSynthetic: DictationEvents.isSynthesized(event.getIntegerValueField(.eventSourceUserData)),
            characters: String(utf16CodeUnits: buffer, count: min(length, buffer.count))
        )
    }

    // MARK: - State machine

    @discardableResult
    private func handle(_ input: GhostTextLogic.Input) -> [GhostTextLogic.Effect] {
        let effects = machine.handle(input)
        for effect in effects { run(effect) }
        return effects
    }

    private func run(_ effect: GhostTextLogic.Effect) {
        switch effect {
        case .scheduleTimer(let gen):
            lastTypedAt = ProcessInfo.processInfo.systemUptime
            // Round 11 (#47): the next session is built while he types, unless the app is excluded.
            if #available(macOS 26.0, *), !GhostTextPolicy.excludedBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") {
                GhostTextModel.shared.prewarm()
            }
            timerTask?.cancel()
            timerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(GhostTextPolicy.pauseDelay))
                guard !Task.isCancelled else { return }
                self?.handle(.pauseFired(gen: gen))
            }
        case .cancelTimer:
            timerTask?.cancel()
            fetchTask?.cancel()
        case .cancelFetch:
            fetchTask?.cancel()
        case .fetch(let gen):
            fetchTask?.cancel()
            fetchTask = Task { @MainActor [weak self] in
                await self?.fetch(gen: gen)
            }
        case .show(let text):
            showOverlay(text)
        case .hide(let reason):
            GhostTextOverlay.shared.hide()
            if reason == .dismissed && !overlayHide { GhostTextLog.record(.dismissed) }
        case .accept(let text):
            // The app the key was pressed in, read now: a later frontmost change must not be mistaken for it.
            let keyApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            Task { @MainActor [weak self] in
                await self?.insert(text, keyApp: keyApp)
            }
        case .swallow:
            break
        }
    }

    /// The overlay's font: the field's own family and size when the helper read them, else the caret-height estimate.
    private static func overlayFont(name: String?, size: Double?, caretHeight: CGFloat) -> NSFont {
        let points = GhostTextGeometry.fontSize(fieldFontSize: size, caretHeight: caretHeight)
        return name.flatMap { NSFont(name: $0, size: points) } ?? .systemFont(ofSize: points)
    }

    private func fetch(gen: Int) async {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPid = Int(frontApp?.processIdentifier ?? 0)
        let frontBundle = frontApp?.bundleIdentifier ?? ""
        let raced: String?? = await TimeoutRace.run(seconds: 3) { () -> String? in
            await XPCHelperClient.shared.focusedTextSnapshotJSON(frontPid: frontPid, frontBundle: frontBundle)
        }
        guard !Task.isCancelled else { GhostTextLog.record(.dropped, reason: .cancelled); return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let snapshot: GhostTextSnapshot
        switch GhostSnapshotRead.classify(raced, frontmostBundleID: front) {
        case .failed(let reason, let axError, let snapshotApp):
            return dropFetch(reason, gen: gen, axError: axError, app: front ?? "", snapshotApp: snapshotApp)
        case .snapshot(let read, let viaFrontmost, let axError):
            if viaFrontmost { GhostTextLog.record(.fallback, axError: axError, app: front ?? "") }
            snapshot = read
        }
        // Round 7 (#31): the allow-list runs first, so the log names the refused role or subrole and its raw value.
        if let refused = GhostInsertGate.refusedBy(role: snapshot.role, subrole: snapshot.subrole) {
            return dropFetch(GhostTextEvent.reason(refused.reason), gen: gen, value: refused.value)
        }
        if let check = GhostTextPolicy.failedCheck(snapshot) { return dropFetch(.policy, gen: gen, check: check) }
        guard let caret = snapshot.caretRect else { return dropFetch(.noCaretRect, gen: gen) }
        guard let field = snapshot.fieldRect else { return dropFetch(.noFieldRect, gen: gen) }
        guard GhostTextGeometry.hasRoom(caret: caret, field: field) else { return dropFetch(.noRoom, gen: gen) }
        guard let prompt = GhostTextPrompt.build(snapshot) else { return dropFetch(.noPrompt, gen: gen) }
        guard let location = snapshot.caretLocation else { return dropFetch(.noCaretLocation, gen: gen) }
        // Same gate as insert: a suggestion is shown only for a field whose insert the helper will accept.
        guard GhostInsertGate.appAllows(token: snapshot.token, isSecure: snapshot.isSecure,
                                        role: snapshot.role, subrole: snapshot.subrole) else {
            return dropFetch(.noToken, gen: gen)
        }
        guard !Task.isCancelled else { GhostTextLog.record(.dropped, reason: .cancelled); return }
        let before = snapshot.textBeforeCaret ?? ""
        Defaults[.ghostTextCalls] += 1
        GhostTextLog.record(.call)

        var completion: GhostTextCompletion = .unavailable
        if #available(macOS 26.0, *) {
            completion = await GhostTextModel.shared.complete(prompt)
        }
        // Round 9 (#31): a cancel after .call still logs one line, so every outcome after .call has one.
        guard !Task.isCancelled else {
            GhostTextLog.record(.dropped, reason: .cancelled)
            return
        }
        // Round 8 (#31): each way the reply gives no suggestion logs one dropped line before the machine goes idle.
        var suggestion: String?
        switch completion {
        case .unavailable:
            GhostTextLog.record(.dropped, reason: .modelUnavailable)
            suggestion = nil
        case .failed(let value):
            GhostTextLog.record(.dropped, reason: .modelError, value: value)
            suggestion = nil
        case .reply(let raw):
            // Round 12 (#47): a repeated word is dropped before the machine sees the suggestion.
            if let cleaned = GhostTextPrompt.clean(raw), let kept = GhostTextPrompt.dedupe(context: before, suggestion: cleaned) {
                suggestion = GhostTextPrompt.join(context: before, suggestion: kept)
            } else {
                let reason = GhostTextPrompt.clean(raw) == nil ? GhostTextEvent.noSuggestionReason(raw) : .cleanedAway
                GhostTextLog.record(.dropped, reason: reason)
                suggestion = nil
            }
        }
        // Round 12 (#47): fit to whole words that fit the field, so the drawn text is exactly what accept inserts.
        if let joined = suggestion {
            let font = Self.overlayFont(name: snapshot.fontName, size: snapshot.fontSize, caretHeight: caret.height)
            let fitted = GhostTextGeometry.fitWords(joined, caret: caret, field: field) { GhostTextOverlay.textSize($0, font: font).width }
            if fitted == nil { GhostTextLog.record(.dropped, reason: .overlayNoRoom) }
            suggestion = fitted
        }
        anchor = GhostTextLogic.Anchor(
            bundleID: snapshot.bundleID,
            caretLocation: location,
            contextTail: String(before.suffix(64)),
            fieldX: snapshot.fieldX, fieldY: snapshot.fieldY,
            fieldWidth: snapshot.fieldWidth, fieldHeight: snapshot.fieldHeight
        )
        pendingCaret = caret
        pendingField = field
        pendingFontName = snapshot.fontName
        pendingFontSize = snapshot.fontSize
        handle(.suggestion(suggestion, gen: gen))
    }

    private func dropFetch(_ reason: GhostTextEvent.Reason, gen: Int, check: GhostTextPolicy.Check? = nil,
                           axError: Int? = nil, app: String? = nil, value: String? = nil, snapshotApp: String? = nil) {
        GhostTextLog.record(.dropped, reason: reason, check: check, axError: axError, app: app, value: value, snapshotApp: snapshotApp)
        handle(.snapshotFailed(gen: gen))
    }

    /// Shows the suggestion only where it can sit beside the caret. No room means no overlay, and the
    /// machine is told so it never stays in the showing state with nothing on screen.
    private func showOverlay(_ text: String) {
        guard let caret = pendingCaret, let field = pendingField else {
            dropOverlay(.overlayNoCaret)
            return
        }
        let font = Self.overlayFont(name: pendingFontName, size: pendingFontSize, caretHeight: caret.height)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let frame = GhostTextGeometry.overlayFrame(
            caret: caret,
            field: field,
            textSize: GhostTextOverlay.textSize(text, font: font),
            primaryHeight: primaryHeight
        ) else {
            dropOverlay(.overlayNoRoom)
            return
        }
        GhostTextOverlay.shared.show(text, frame: frame, font: font)
        GhostTextLog.record(.shown, latencyMs: lastTypedAt.map { GhostTextEvent.latencyMs(from: $0, to: ProcessInfo.processInfo.systemUptime) })
    }

    /// Logs the one reason the overlay could not be shown, then tells the machine to go idle without logging a dismissal.
    private func dropOverlay(_ reason: GhostTextEvent.Reason) {
        GhostTextLog.record(.dropped, reason: reason)
        overlayHide = true
        handle(.focusChanged)
        overlayHide = false
    }

    // MARK: - Accept

    /// What one accept attempt produced; `insert` writes it as the key's only log line.
    private struct InsertOutcome {
        var event: GhostTextEvent = .dropped
        var reason: GhostTextEvent.Reason?
        var result: Int?
        var axError: Int?
        var app: String?
        var value: String?
        var snapshotApp: String?
    }

    /// Runs the accept. When nothing can have been written, the Option+Tab it swallowed goes back to the app it was
    /// pressed in, so the key is never lost for nothing (#47, finding 5).
    private func insert(_ text: String, keyApp: String?) async {
        var outcome = await attemptInsert(text)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if GhostInsertGate.passThrough(result: outcome.result, keyApp: keyApp, frontNow: front) {
            if await XPCHelperClient.shared.postGhostAcceptKey() {
                outcome.event = .passedThrough
            } else {
                // Round 9 (#31): a lost pass-through is logged with its reason, so the key is never dropped silently.
                outcome.value = outcome.reason?.rawValue
                outcome.reason = .passThroughFailed
                outcome.event = .dropped
            }
        }
        // Round 11 (#31): one accept key, one line, with the helper's reply whenever there was one.
        GhostTextLog.record(outcome.event, reason: outcome.reason, insertResult: outcome.result, axError: outcome.axError,
                            app: outcome.app, value: outcome.value, snapshotApp: outcome.snapshotApp)
    }

    /// Re-reads the field, checks the gate and the anchor, then asks the helper to write into the element that read found.
    /// Results 0, 3 and 7 add text, so they count as accepted; anything else is dropped.
    /// Returns the outcome; it never logs.
    private func attemptInsert(_ text: String) async -> InsertOutcome {
        guard let anchor else {
            return InsertOutcome(reason: .noAnchor)
        }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPid = Int(frontApp?.processIdentifier ?? 0)
        let frontBundle = frontApp?.bundleIdentifier ?? ""
        let raced: String?? = await TimeoutRace.run(seconds: 3) { () -> String? in
            await XPCHelperClient.shared.focusedTextSnapshotJSON(frontPid: frontPid, frontBundle: frontBundle)
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let now: GhostTextSnapshot
        switch GhostSnapshotRead.classify(raced, frontmostBundleID: front) {
        case .failed(let reason, let axError, let snapshotApp):
            return InsertOutcome(reason: reason, axError: axError, app: front ?? "", snapshotApp: snapshotApp)
        case .snapshot(let snapshot, _, _):
            now = snapshot
        }
        guard GhostInsertGate.appAllows(token: now.token, isSecure: now.isSecure, role: now.role, subrole: now.subrole),
              let token = now.token else {
            if let refused = GhostInsertGate.refusedBy(role: now.role, subrole: now.subrole) {
                return InsertOutcome(reason: GhostTextEvent.reason(refused.reason), app: front ?? "", value: refused.value)
            }
            return InsertOutcome(reason: .noToken, app: front ?? "")
        }
        guard GhostTextLogic.insertAllowed(anchor: anchor, now: now) else {
            return InsertOutcome(reason: .anchorMismatch)
        }
        let result = await XPCHelperClient.shared.ghostInsert(token: token, location: anchor.caretLocation, text: text,
                                                              frontPid: Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0))
        // 0 inserted, 3 unverified (may have landed, so never retried), 7 typed fallback.
        if [0, 3, 7].contains(result) {
            return InsertOutcome(event: .accepted, result: result)
        }
        return InsertOutcome(reason: .insertFailed, result: result)
    }
}

private let ghostTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<GhostTextManager>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap runs on the main run loop, so the main actor is the current executor.
    return MainActor.assumeIsolated {
        manager.handleTap(type: type, event: event)
    }
}
