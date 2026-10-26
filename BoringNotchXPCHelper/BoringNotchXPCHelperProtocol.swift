//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    func postPasteKeystroke(_ keyCode: Int, with reply: @escaping (Bool) -> Void)
    /// The focused text field as JSON (see GhostTextSnapshot keys), or nil when Accessibility is not trusted
    /// or nothing has focus. A secure field's value is never read.
    func focusedTextSnapshot(with reply: @escaping (String?) -> Void)
    func ghostInsert(_ location: Int, _ text: String, with reply: @escaping (Int) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Which process is burning the CPU. Asked of the helper because the app is sandboxed and
    // cannot see one, and this service is not.
    func topProcessName(with reply: @escaping (String?) -> Void)
    func topMemoryProcess(with reply: @escaping (String?) -> Void)
    func topPowerProcess(with reply: @escaping (String?) -> Void)
    /// The whole ranking, as JSON, rather than one name. Returns a JSON array of
    /// `{"name": String, "cpu": Double, "mem": UInt64}`, busiest first.
    ///
    /// A JSON `String?` and not a typed array on purpose: `NSXPCInterface` needs explicit
    /// class whitelisting for collection reply types, which the client's generic wrapper does
    /// not expose. A string needs no ceremony and versions trivially.
    func topProcesses(_ limit: Int, with reply: @escaping (String?) -> Void)
    /// Runs the Tailscale CLI, which a sandboxed app cannot. `subcommand` is matched against
    /// a whitelist, never passed through as argv.
    func runTailscale(_ subcommand: String, with reply: @escaping (String?) -> Void)
    /// `system_profiler -json SPBluetoothDataType`, which a sandboxed app cannot spawn.
    ///
    /// The classic-Bluetooth battery levels live nowhere else that is reachable. Measured on
    /// this machine with AirPods connected: CoreBluetooth's `retrieveConnectedPeripherals`
    /// returns zero, `ioreg -k BatteryPercent` is empty, and the whole
    /// `AppleDeviceManagementHIDEventService` class contains only the internal keyboard --
    /// while `system_profiler` has `device_batteryLevelLeft = 82%` sitting right there.
    func bluetoothDevices(with reply: @escaping (String?) -> Void)
    // Dictation rewrite (U4). The helper holds the key file read, AX trust and the event tap.
    /// The strict OpenRouter key from ~/.config/openrouter-key, trimmed. nil if missing or empty.
    func openRouterKey(with reply: @escaping (String?) -> Void)
    /// The focused text value, or nil when unreadable, secure, or longer than 20 000 characters.
    func focusedTextValue(with reply: @escaping (String?) -> Void)
    /// Records the focused element for the swaps. JSON of FocusedField, or nil.
    func beginTracking(with reply: @escaping (String?) -> Void)
    /// Turns on app pid's accessibility tree (Chromium/Electron build it only on request) and remembers pid as the take's app. True if a focused element now resolves.
    func prepareFocus(_ pid: Int, with reply: @escaping (Bool) -> Void)
    /// UTF-16 caret. -1 unknown, -2 focus moved or nothing tracked.
    func caretLocation(with reply: @escaping (Int) -> Void)
    func stringForRange(_ location: Int, _ length: Int, with reply: @escaping (String?) -> Void)
    /// Swap reply codes: 0 ok, 1 selectFailed, 2 setFailed, 3 verifyMismatch, 4 noFocus, 5 focusMoved, 6 notTrusted.
    /// Codes 1, 2, 4, 5 and 6 leave the text unchanged.
    func axReplace(_ location: Int, _ length: Int, _ text: String, with reply: @escaping (Int) -> Void)
    func axSelectThenType(_ location: Int, _ length: Int, _ text: String, _ caretAfter: Int, with reply: @escaping (Int) -> Void)
    func typeSwap(_ suffixGraphemes: Int, _ oldGraphemes: Int, _ text: String, with reply: @escaping (Int) -> Void)
    func endTracking()
}

/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:

     connectionToService = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
     connectionToService.remoteObjectInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
     connectionToService.resume()

 Once you have a connection to the service, you can use it like this:

     if let proxy = connectionToService.remoteObjectProxy as? BoringNotchXPCHelperProtocol {
         proxy.performCalculation(firstNumber: 23, secondNumber: 19) { result in
             NSLog("Result of calculation is: \(result)")
         }
     }

 And, when you are finished with the service, clean up the connection like this:

     connectionToService.invalidate()
*/
