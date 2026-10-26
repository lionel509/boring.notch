//
//  GhostTextManager.swift
//  boringNotch
//

import AppKit
import ApplicationServices
import Defaults
import SwiftUI

/// Owns the key and mouse tap for ghost text. Decisions live in `GhostTextLogic`; this class
/// creates the tap, runs the pause timer and the helper and model calls, and carries out effects.
/// Nothing here logs. Counters go to Defaults.
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
    /// Non-nil only while the notch fallback is showing a suggestion.
    @Published private(set) var notchSuggestion: String? = nil
    @Published private(set) var callsThisSession = 0

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var workspaceObserver: NSObjectProtocol?
    private var machine = GhostTextLogic.Machine()
    private var timerTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var lastContext: String?
    private var pendingCaret: CGRect?
    private var clipboard = ClipboardKeeper()

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

        // Default tap only: a listen-only tap cannot swallow Shift+Tab, so focus would move and
        // the paste would land in the wrong field. No fallback on purpose.
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
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            handle(.focusChanged)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let effects = handle(.key(Self.classify(keyCode: keyCode, flags: event.flags)))
            return effects.contains(.swallow) ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static func classify(keyCode: Int64, flags: CGEventFlags) -> GhostTextLogic.Key {
        if keyCode == 48,
           flags.contains(.maskShift),
           !flags.contains(.maskCommand),
           !flags.contains(.maskControl),
           !flags.contains(.maskAlternate) {
            return .shiftTab
        }
        if keyCode == 53 { return .escape }
        if flags.contains(.maskCommand) { return .command }
        return .other
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
        case .fetch(let gen):
            fetchTask?.cancel()
            fetchTask = Task { @MainActor [weak self] in
                await self?.fetch(gen: gen)
            }
        case .show(let text):
            if let caret = pendingCaret {
                GhostTextOverlay.shared.show(text, axCaret: caret)
                notchSuggestion = nil
            } else {
                GhostTextOverlay.shared.hide()
                notchSuggestion = text
            }
        case .hide:
            GhostTextOverlay.shared.hide()
            notchSuggestion = nil
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
              let prompt = GhostTextPrompt.build(snapshot),
              snapshot.textBeforeCaret != lastContext else {
            lastContext = nil
            handle(.snapshotFailed(gen: gen))
            return
        }
        lastContext = snapshot.textBeforeCaret
        pendingCaret = caretRect(snapshot)
        callsThisSession += 1
        Defaults[.ghostTextCalls] += 1

        var raw: String? = nil
        if #available(macOS 26.0, *) {
            raw = await GhostTextModel.shared.complete(prompt)
        }
        guard !Task.isCancelled else { return }
        let suggestion = GhostTextPrompt.clean(raw).map {
            GhostTextPrompt.join(context: snapshot.textBeforeCaret ?? "", suggestion: $0)
        }
        handle(.suggestion(suggestion, gen: gen))
    }

    private func caretRect(_ s: GhostTextSnapshot) -> CGRect? {
        guard s.hasCaret, let x = s.caretX, let y = s.caretY,
              let w = s.caretWidth, let h = s.caretHeight else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Accept

    /// Same primitives as dictation: a changeCount-guarded clipboard write, then Cmd-V.
    private func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        guard await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: false) else { return }
        let change = clipboard.write(text, to: pasteboard)
        await waitForModifiersReleased(timeout: 1.0)
        guard pasteboard.changeCount == change else {
            clipboard.release(change)
            return
        }
        let posted = await XPCHelperClient.shared.postPasteKeystroke(keyCode: PasteKeycode.currentV())
        guard posted else {
            clipboard.release(change)
            return
        }
        try? await Task.sleep(for: .milliseconds(1000))
        clipboard.restore(to: pasteboard, ifChangeCountIs: change)
    }

    /// Shift is still down from the Shift+Tab itself, so wait for the modifiers to clear before Cmd-V.
    private func waitForModifiersReleased(timeout: TimeInterval) async {
        let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let deadline = Date().addingTimeInterval(timeout)
        while !NSEvent.modifierFlags.intersection(watched).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
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
