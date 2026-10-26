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
            if reason == .dismissed { GhostTextLog.record(.dismissed) }
        case .accept(let text):
            Task { @MainActor [weak self] in
                await self?.insert(text)
            }
        case .swallow:
            break
        }
    }

    private func fetch(gen: Int) async {
        let json = await XPCHelperClient.shared.focusedTextSnapshotJSON()
        guard let snapshot = json.flatMap(GhostTextSnapshot.decode),
              GhostTextPolicy.shouldRequest(snapshot),
              let caret = snapshot.caretRect,
              let field = snapshot.fieldRect,
              GhostTextGeometry.hasRoom(caret: caret, field: field),
              let prompt = GhostTextPrompt.build(snapshot),
              let location = snapshot.caretLocation else {
            GhostTextLog.record(.dropped)
            handle(.snapshotFailed(gen: gen))
            return
        }
        guard !Task.isCancelled else { return }
        let before = snapshot.textBeforeCaret ?? ""
        Defaults[.ghostTextCalls] += 1
        GhostTextLog.record(.call)

        var raw: String? = nil
        if #available(macOS 26.0, *) {
            raw = await GhostTextModel.shared.complete(prompt)
        }
        guard !Task.isCancelled else { return }
        let suggestion = GhostTextPrompt.clean(raw).map {
            GhostTextPrompt.join(context: before, suggestion: $0)
        }
        anchor = GhostTextLogic.Anchor(
            bundleID: snapshot.bundleID,
            caretLocation: location,
            contextTail: String(before.suffix(64))
        )
        pendingCaret = caret
        pendingField = field
        handle(.suggestion(suggestion, gen: gen))
    }

    /// Shows the suggestion only where it can sit beside the caret. No room means no overlay, and the
    /// machine is told so it never stays in the showing state with nothing on screen.
    private func showOverlay(_ text: String) {
        guard let caret = pendingCaret, let field = pendingField else {
            handle(.focusChanged)
            return
        }
        let fontSize = GhostTextGeometry.fontSize(caretHeight: caret.height)
        let measure = NSTextField(labelWithString: text)
        measure.font = .systemFont(ofSize: fontSize)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let frame = GhostTextGeometry.overlayFrame(
            caret: caret,
            field: field,
            textSize: measure.intrinsicContentSize,
            primaryHeight: primaryHeight
        ) else {
            handle(.focusChanged)
            return
        }
        GhostTextOverlay.shared.show(text, frame: frame, fontSize: fontSize)
        GhostTextLog.record(.shown)
    }

    // MARK: - Accept

    /// Re-reads the field, checks it still matches the anchor, then asks the helper for an insert at the caret.
    /// Results 0, 3 and 7 add text, so they count as accepted; anything else is dropped.
    private func insert(_ text: String) async {
        guard let anchor else {
            GhostTextLog.record(.dropped)
            return
        }
        let now = (await XPCHelperClient.shared.focusedTextSnapshotJSON()).flatMap(GhostTextSnapshot.decode)
        guard let now, GhostTextLogic.insertAllowed(anchor: anchor, now: now) else {
            GhostTextLog.record(.dropped)
            return
        }
        let result = await XPCHelperClient.shared.ghostInsert(location: anchor.caretLocation, text: text)
        // 0 inserted, 3 unverified (may have landed, so never retried), 7 typed fallback.
        if [0, 3, 7].contains(result) {
            GhostTextLog.record(.accepted)
        } else {
            GhostTextLog.record(.dropped)
        }
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
