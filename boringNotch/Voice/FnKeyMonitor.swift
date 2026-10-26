//
//  FnKeyMonitor.swift
//  boringNotch
//

import AppKit
import ApplicationServices
import Defaults

/// Owns the session event tap that turns holding fn into push-to-talk. It tries an active
/// tap first and falls back to listen-only. The decisions are in `FnKeyLogic`, and this
/// class only creates the tap and forwards what the classifier says.
@MainActor
final class FnKeyMonitor: ObservableObject {
    static let shared = FnKeyMonitor()

    enum Mode: Equatable {
        case off
        case active
        case listenOnly
        case denied
    }

    @Published private(set) var mode: Mode = .off

    /// Every untagged key or mouse event the tap sees, before the fn logic. The rewrite uses it to abort
    /// when the user touches the text. Tagged events (ours) never reach it.
    var userInput: ((CGEventType) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// True while the session tap exists: key events reach the rewrite's abort path.
    var isTapLive: Bool { tap != nil }
    private var logic = FnKeyLogic.State()

    private init() {}

    func start() {
        guard tap == nil, Defaults[.dictateWithFn] else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fnTapCallback,
            userInfo: userInfo
        )
        var tapMode = Mode.active
        if created == nil {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: fnTapCallback,
                userInfo: userInfo
            )
            tapMode = .listenOnly
        }
        guard let created else {
            mode = .denied
            return
        }

        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        mode = tapMode
    }

    /// Turns the setting off: a running fn take is discarded, then the tap goes away.
    func disable() {
        // Queued behind any tap event already dispatched, so those still reach the reducer first.
        if logic.fnHeld || logic.handsFreeOpen {
            send(.abort, at: ProcessInfo.processInfo.systemUptime)
        }
        logic = FnKeyLogic.State()
        stop()
    }

    func stop() {
        // A fn hold still open when the tap goes away must not leave a take recording.
        if logic.fnHeld {
            send(.cancel, at: ProcessInfo.processInfo.systemUptime)
        }
        logic = FnKeyLogic.State()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        mode = .off
    }

    func restart() {
        stop()
        start()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our own synthesized events (the rewrite's keystrokes and paste) are not user input.
        if DictationEvents.isSynthesized(event.getIntegerValueField(.eventSourceUserData)) { return Unmanaged.passUnretained(event) }
        switch type {
        case .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            userInput?(type)
        default:
            break
        }
        let now: TimeInterval
        let input: FnKeyLogic.Input
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            now = ProcessInfo.processInfo.systemUptime
            // Re-enable at once, then resync fn in case a fn-up was lost while the tap was off.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let fnDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
            input = .resync(fnDown: fnDown)
        case .flagsChanged:
            now = eventTime(event)
            let flags = event.flags
            let otherModifiers = !flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
            input = .flags(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                fn: flags.contains(.maskSecondaryFn),
                otherModifiers: otherModifiers
            )
        case .keyDown:
            now = eventTime(event)
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // A fresh Space keyDown whose flags lack fn means a fn-up was lost: resync before classifying.
            if keyCode == FnKeyLogic.spaceKeyCode && !isRepeat && logic.fnHeld && !event.flags.contains(.maskSecondaryFn) && !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn) {
                send(FnKeyLogic.classify(&logic, .resync(fnDown: false), at: now).event, at: now)
            }
            input = .keyDown(keyCode: keyCode, isRepeat: isRepeat)
        case .keyUp:
            now = eventTime(event)
            input = .keyUp(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)))
        default:
            return Unmanaged.passUnretained(event)
        }

        let output = FnKeyLogic.classify(&logic, input, at: now)
        send(output.event, at: now)
        // Only the Space of an fn+Space chord is ever swallowed, and only with an active tap.
        if output.swallow && mode == .active {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// The event's own time, on the same since-boot clock as `systemUptime`. A late callback
    /// must not stretch a short tap into a hold, or a hold into a tap.
    private func eventTime(_ event: CGEvent) -> TimeInterval {
        NSEvent(cgEvent: event)?.timestamp ?? ProcessInfo.processInfo.systemUptime
    }

    /// Hands a classifier event to the manager on the next main-queue turn, with its own time.
    private func send(_ event: DictationHotkeyLogic.Event?, at time: TimeInterval) {
        guard let event else { return }
        DispatchQueue.main.async {
            VoiceDictationManager.shared.fnKey(event, at: time)
        }
    }
}

private let fnTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap is on the main run loop, so this callback always runs on the main actor.
    return MainActor.assumeIsolated {
        monitor.handle(type: type, event: event)
    }
}
