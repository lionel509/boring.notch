// AX spike for dictation rewrites (#13, v4 item 1). Run from an AX-trusted Terminal.
// Build: swiftc -O -framework ApplicationServices -framework AppKit scripts/ax-spike/main.swift \
//          -o ~/worktrees/boring.notch/.target/ax-spike
// Usage: ax-spike <seconds>
// The operator focuses a field that already contains "hello world", then the countdown runs.
// Fixed text only; nothing from the user's own documents is read or printed.
import AppKit
import ApplicationServices

let countdown = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
let target = "hello there"
let baseline = "hello world"

func axString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
    return value as? String
}

func axSettable(_ element: AXUIElement, _ attr: String) -> String {
    var settable: DarwinBoolean = false
    let err = AXUIElementIsAttributeSettable(element, attr as CFString, &settable)
    return err == .success ? "\(settable.boolValue)" : "err\(err.rawValue)"
}

func setRange(_ element: AXUIElement, location: Int, length: Int) -> AXError {
    var range = CFRange(location: location, length: length)
    guard let value = AXValueCreate(.cfRange, &range) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
}

func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

func typeText(_ text: String) {
    for scalar in text.utf16 {
        var unit = scalar
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Puts the field back to "hello world" with the caret at the end.
func resetField() {
    postKey(0, flags: .maskCommand)  // cmd+a
    usleep(120_000)
    typeText(baseline)
    usleep(300_000)
}

func sleepMs(_ ms: UInt32) { usleep(ms * 1000) }

// Mechanisms, tried in order. Each returns an AXError-like code (0 = call succeeded).
let mechanisms: [(name: String, run: (AXUIElement) -> Int32)] = [
    ("A AXReplaceRangeWithText", { el in
        // Parameter encoding: CFArray of [AXValue(CFRange), CFString]. Best effort, the row shows the result.
        var range = CFRange(location: 6, length: 5)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return -1 }
        let param: [Any] = [rangeValue, "there"]
        // Set through the attribute setter; if the app rejects the encoding the row shows its AXError.
        return AXUIElementSetAttributeValue(el, "AXReplaceRangeWithText" as CFString, param as CFArray).rawValue
    }),
    ("B range + AXSelectedText", { el in
        let r = setRange(el, location: 6, length: 5)
        guard r == .success else { return r.rawValue }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, "there" as CFString).rawValue
    }),
    ("C range + unicode CGEvents", { el in
        let r = setRange(el, location: 6, length: 5)
        guard r == .success else { return r.rawValue }
        usleep(100_000)
        typeText("there")
        return 0
    }),
    ("D arrows + unicode CGEvents", { _ in
        // The caret is at the end after the reset, so shift+left x5 selects "world".
        for _ in 0..<5 { postKey(123, flags: .maskShift) }
        usleep(100_000)
        typeText("there")
        return 0
    }),
]

func describe(_ code: Int32) -> String { code == 0 ? "ok" : "fail(AXError \(code))" }

// Countdown, then inspect the focused element.
print("Focus the field now. Starting in \(Int(countdown)) s")
sleepMs(UInt32(countdown * 1000))

let system = AXUIElementCreateSystemWide()
var focusedRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
      let focusedRaw = focusedRef else {
    print("no focused element; AX trusted? \(AXIsProcessTrusted())")
    exit(1)
}
let element = focusedRaw as! AXUIElement
var pid: pid_t = 0
AXUIElementGetPid(element, &pid)
let app = NSRunningApplication(processIdentifier: pid)
let bundle = app?.bundleIdentifier ?? "unknown"
let role = axString(element, kAXRoleAttribute as String) ?? "none"
let appElement = AXUIElementCreateApplication(pid)

var paramNames: CFArray?
AXUIElementCopyParameterizedAttributeNames(element, &paramNames)
let hasReplace = ((paramNames as? [String]) ?? []).contains("AXReplaceRangeWithText")

print("bundle=\(bundle) role=\(role) settable(selRange)=\(axSettable(element, kAXSelectedTextRangeAttribute as String)) settable(selText)=\(axSettable(element, kAXSelectedTextAttribute as String)) AXReplaceRangeWithText=\(hasReplace)")

// Electron and Chromium only expose their web tree after these flags are set.
var flagsSet = false
func setElectronFlags(_ on: Bool) {
    let value: CFTypeRef = on ? kCFBooleanTrue : kCFBooleanFalse
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, value)
    AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, value)
}

func runPass(label: String) {
    for mechanism in mechanisms {
        resetField()
        let code = mechanism.run(element)
        sleepMs(300)
        let value = axString(element, kAXValueAttribute as String) ?? "<no AXValue>"
        let verdict: String
        if code != 0 {
            verdict = describe(code)
        } else if value == target {
            verdict = "ok"
        } else {
            verdict = "mismatch(read=\"\(value)\")"
        }
        print("| \(bundle) | \(label) | \(mechanism.name) | \(verdict) |")
    }
}

// Pass 1: as is. Pass 2: Electron and Chromium flags on, then the same four tries.
runPass(label: "plain")
setElectronFlags(true)
flagsSet = true
sleepMs(500)
runPass(label: "manualAX")
setElectronFlags(false)
if flagsSet { print("restored AXManualAccessibility and AXEnhancedUserInterface to false") }
