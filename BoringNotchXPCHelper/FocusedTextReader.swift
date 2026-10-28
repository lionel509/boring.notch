//
//  FocusedTextReader.swift
//  BoringNotchXPCHelper
//
//  Reads the focused text field for the ghost-text feature. Lives in the helper because
//  Accessibility trust is held by this process, not the sandboxed app. A secure field's
//  value is never read.
//

import AppKit
import ApplicationServices
import Foundation

enum FocusedTextReader {
    /// Context kept before the caret, in UTF-16 units (AX ranges are UTF-16).
    private static let maxContextUnits = 4000

    /// Pids we have already asked to expose their AX tree (Chromium/Electron need the flag).
    nonisolated(unsafe) private static var primedPIDs = Set<pid_t>()

    /// The field the newest read found, for the one-use token ghostInsert needs (#47, review finding 5).
    nonisolated(unsafe) private static var slot = GhostTokenSlot<(pid: pid_t, element: AXUIElement)>()
    private static let slotLock = NSLock()

    /// JSON snapshot of the focused field, or `{"failure":"<token>"[,"axError":N]}` saying why there is none (#47).
    static func snapshotJSON() -> String {
        clearToken()
        guard AXIsProcessTrusted() else { return failure("untrusted") }
        let system = AXUIElementCreateSystemWide()
        var dict: [String: Any] = [:]
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &raw)
        let app: AXUIElement
        if err == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            app = raw as! AXUIElement
        } else if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid > 0 {
            // The system-wide lookup failed: use the frontmost app. The app side accepts this only when it is frontmost too.
            app = AXUIElementCreateApplication(pid)
            dict["focusVia"] = "frontmost"
            dict["axError"] = Int(err.rawValue)
        } else {
            return failure("noFocusedApp", axError: Int(err.rawValue))
        }
        AXUIElementSetMessagingTimeout(app, 0.25)

        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let running = NSRunningApplication(processIdentifier: pid)
        dict["bundleID"] = running?.bundleIdentifier ?? ""
        dict["appName"] = running?.localizedName ?? ""

        if !primedPIDs.contains(pid) {
            primedPIDs.insert(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        dict["windowTitle"] = element(app, kAXFocusedWindowAttribute as String)
            .flatMap { string($0, kAXTitleAttribute as String) } ?? ""

        guard let focused = element(app, kAXFocusedUIElementAttribute as String) else {
            return encode(dict)
        }
        let role = string(focused, kAXRoleAttribute as String) ?? ""
        let subrole = string(focused, kAXSubroleAttribute as String) ?? ""
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
        dict["role"] = role
        dict["subrole"] = subrole
        dict["isSecure"] = isSecure

        // Branch on isSecure before any value attribute is touched.
        if isSecure {
            return encode(dict)
        }

        guard let value = string(focused, kAXValueAttribute as String) else {
            return encode(dict)
        }
        let ns = value as NSString
        guard let selection = cfRange(focused, kAXSelectedTextRangeAttribute as String) else {
            return encode(dict)
        }
        // A selection is replaced by the paste, so there is no caret to continue from.
        guard selection.length == 0 else {
            return encode(dict)
        }
        let caretEnd = selection.location + selection.length
        let before = ns.substring(to: min(max(caretEnd, 0), ns.length))
        dict["textBeforeCaret"] = tail(before, units: maxContextUnits)
        // Only whether the caret sits at the end of the field is sent. The text after it never leaves this process.
        dict["caretLocation"] = caretEnd
        let after = ns.substring(from: min(max(caretEnd, 0), ns.length))
        dict["caretAtEnd"] = after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let rect = caretRect(focused, caretEnd: caretEnd) {
            dict["caretX"] = Double(rect.origin.x)
            dict["caretY"] = Double(rect.origin.y)
            dict["caretWidth"] = Double(rect.width)
            dict["caretHeight"] = Double(rect.height)
        }
        if let frame = fieldFrame(focused) {
            dict["fieldX"] = Double(frame.origin.x)
            dict["fieldY"] = Double(frame.origin.y)
            dict["fieldWidth"] = Double(frame.width)
            dict["fieldHeight"] = Double(frame.height)
        }
        dict["token"] = issueToken(pid: pid, element: focused)
        return encode(dict)
    }

    private static func failure(_ token: String, axError: Int? = nil) -> String {
        var dict: [String: Any] = ["failure": token]
        if let axError { dict["axError"] = axError }
        return encode(dict)
    }

    /// Forgets the field of the previous read, so its token can no longer insert anything.
    static func clearToken() {
        slotLock.lock()
        defer { slotLock.unlock() }
        slot.clear()
    }

    /// Stores the field this read found and returns the one-use token that names it.
    static func issueToken(pid: pid_t, element: AXUIElement) -> String {
        slotLock.lock()
        defer { slotLock.unlock() }
        return slot.put((pid, element), now: ProcessInfo.processInfo.systemUptime)
    }

    /// The field behind a token, once. nil when the token is unknown, used, or replaced by a newer read.
    static func takeToken(_ token: String) -> (pid: pid_t, element: AXUIElement, age: TimeInterval)? {
        slotLock.lock()
        defer { slotLock.unlock() }
        guard let taken = slot.take(token, now: ProcessInfo.processInfo.systemUptime) else { return nil }
        return (taken.value.pid, taken.value.element, taken.age)
    }

    /// Bounds of the caret. Uses the character before it first (x = its right edge, width 0), because some
    /// apps answer a zero-length range with a line-start rect. The zero-length range is only used at location 0.
    private static func caretRect(_ element: AXUIElement, caretEnd: Int) -> CGRect? {
        if caretEnd > 0 {
            guard let prev = bounds(element, location: caretEnd - 1, length: 1), prev.height > 0
            else { return nil }
            return CGRect(x: prev.maxX, y: prev.origin.y, width: 0, height: prev.height)
        }
        if let rect = bounds(element, location: 0, length: 0), rect.height > 0 {
            return rect
        }
        return nil
    }

    /// Position and size of the whole field in AX coordinates.
    private static func fieldFrame(_ element: AXUIElement) -> CGRect? {
        guard let posRef = copy(element, kAXPositionAttribute as String), CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = copy(element, kAXSizeAttribute as String), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func bounds(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
              let raw = out, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Last `units` UTF-16 units of `text`, without splitting a surrogate pair at the front.
    private static func tail(_ text: String, units: Int) -> String {
        let ns = text as NSString
        guard ns.length > units else { return text }
        var start = ns.length - units
        if start < ns.length, UTF16.isTrailSurrogate(ns.character(at: start)) {
            start += 1
        }
        return ns.substring(from: start)
    }

    private static func encode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"failure":"encodeFailed"}"#
        }
        return text
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copy(parent, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func string(_ parent: AXUIElement, _ attribute: String) -> String? {
        copy(parent, attribute) as? String
    }

    private static func cfRange(_ parent: AXUIElement, _ attribute: String) -> CFRange? {
        guard let raw = copy(parent, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func copy(_ parent: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &out) == .success else { return nil }
        return out
    }
}
