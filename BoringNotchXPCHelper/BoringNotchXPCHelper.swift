//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import AppKit
import ApplicationServices
import OSLog
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {

    /// The element the rewrite swaps into, from `beginTracking` until `endTracking`.
    private var trackedElement: AXUIElement?
    /// The app the take was prepared for (#13 r5 / U2). Its focus is read through the app element only while it is frontmost.
    private static var preparedPid: pid_t = 0
    /// The app whose AXManualAccessibility this helper turned on, so it can be turned back off.
    private static var manualAXPid: pid_t = 0

    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    /// The busiest process by name, or `nil` when nothing in particular is to blame.
    ///
    /// This lives in the helper because it cannot live in the app. Measured from inside the
    /// app sandbox, on this machine: `proc_listpids` returns zero pids -- not a filtered list,
    /// nothing at all; `sysctl(KERN_PROC_ALL)` does return all 589 processes with their names,
    /// but the `p_pctcpu` it carries reads 0 for every one of them, because the kernel stopped
    /// maintaining that field and `ps` computes its own figure instead; and `proc_pid_rusage`,
    /// which has the real number, answers for exactly 1 of those 589 -- the app itself.
    ///
    /// Out here none of that applies. Names still come from the process table in one call, and
    /// the CPU time comes from `proc_pid_rusage` per pid, which is now allowed.
    @objc func topProcessName(with reply: @escaping (String?) -> Void) {
        // Off the reply thread: this deliberately sleeps between two readings.
        DispatchQueue.global(qos: .utility).async {
            reply(Self.busiestProcess())
        }
    }

    /// A single reading cannot answer this. `proc_pid_rusage` reports CPU burned since a
    /// process started, so the largest figure belongs to whatever has been running longest --
    /// which is never the answer to *what just spiked*. Two readings, differenced.
    /// `ri_user_time` and `ri_system_time` are mach absolute time, *not* nanoseconds. The two
    /// are the same thing on Intel, where the timebase is 1/1, which is why the difference goes
    /// unnoticed until it runs on Apple Silicon -- there the timebase is 125/3, so the raw
    /// figures are about 41.7x too small. Divided by a wall clock that really is in nanoseconds,
    /// a process pinning a whole core measured as 0.03 of one, fell under the floor, and the
    /// alert blamed nobody while the machine sat at 100%.
    private static let machToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    private static func busiestProcess(over interval: TimeInterval = 0.3) -> String? {
        let names = processTable()
        guard !names.isEmpty else { return nil }

        let pids = Array(names.keys)
        let first = cpuTimes(of: pids)
        guard !first.isEmpty else { return nil }

        let started = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: interval)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started)
        guard elapsed > 0 else { return nil }

        var busiest: pid_t = 0
        var cores = 0.0
        let second = cpuTimes(of: pids)
        for (pid, after) in second {
            guard let before = first[pid], after > before else { continue }
            let share = Double(after - before) * machToNanoseconds / elapsed
            if share > cores { cores = share; busiest = pid }
        }
        let name = names[busiest].map { displayName(of: busiest, fallback: $0) }
        Logger(subsystem: "theboringteam.boringnotch", category: "SystemAlert").notice("""
            helper: \(second.count, privacy: .public) of \(pids.count, privacy: .public) \
            readable, top \(cores, format: .fixed(precision: 2), privacy: .public) cores = \
            \(name ?? "?", privacy: .public)
            """)
        // Below half a core, nobody is to blame. A load spread across forty processes has no
        // culprit, and naming the largest of forty small ones is a confident wrong answer --
        // worse than saying nothing, because the figure beside it makes it look checked.
        guard cores >= 0.5 else { return nil }
        return name
    }

    // MARK: - Naming the process

    /// What to call the process the numbers point at.
    ///
    /// `p_comm` is the wrong answer twice over: it is the *executable's* name rather than the
    /// app's, and the kernel caps it at `MAXCOMLEN` -- sixteen characters. Measured on this
    /// machine, that is what made Safari say `com.apple.WebKit`, Visual Studio Code say
    /// `Code Helper (Plu` and Obsidian say `Obsidian Helper `. A name cut off mid-word, for a
    /// process nobody could act on even spelled out in full.
    ///
    /// The executable path answers both halves. Every app process runs out of a bundle, and the
    /// *outermost* `.app` on its path is the thing you would quit -- Electron helpers nest their
    /// own `.app` inside the parent's `Frameworks/`, so the first one on the path wins and the
    /// last one is noise.
    ///
    /// Only ever called for the one pid that won, so a path lookup and a plist-free string walk
    /// cost nothing beside the two passes over six hundred processes that chose it.
    private static func displayName(of pid: pid_t, fallback: String) -> String {
        guard let path = executablePath(of: pid) else { return fallback }
        if let app = owningApp(in: path) { return app }

        // An XPC service belongs to whoever asked for it, and Safari's tabs are the case that
        // matters: `com.apple.WebKit.WebContent` runs out of WebKit.framework, so there is no
        // `.app` anywhere on its path to find. Deliberately *only* for services -- a command
        // line tool has no `.app` on its path either, and its responsible process is the
        // terminal it was launched from, so widening this would turn `python 26.2 W` into
        // `Terminal 26.2 W` and name the one thing that is certainly not at fault.
        if path.contains(".xpc/"),
           let owner = responsibleProcess(of: pid),
           let ownerPath = executablePath(of: owner),
           let app = owningApp(in: ownerPath) {
            return app
        }

        // Not in a bundle at all: a CLI, a daemon, a bare helper binary. Its own filename is the
        // best name it has, and unlike `p_comm` it is not cut at sixteen characters --
        // `ContinuityCaptureAgent` rather than `ContinuityCaptur`.
        return (path as NSString).lastPathComponent
    }

    private static func owningApp(in path: String) -> String? {
        guard let bundle = (path as NSString).pathComponents.first(where: { $0.hasSuffix(".app") })
        else { return nil }
        return String(bundle.dropLast(".app".count))
    }

    private static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE. Root-owned processes refuse, which is the same set that
        // refuses `proc_pid_rusage`, so they were never going to win anything anyway.
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `responsibility_get_pid_responsible_for_pid` is what Activity Monitor groups by. It ships
    /// in libsystem and appears in no public header, so it is reached by symbol rather than
    /// declared; if it ever stops being there, the caller falls back on the path.
    private static let responsibleForPid: (@convention(c) (pid_t) -> pid_t)? = {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsibleProcess(of pid: pid_t) -> pid_t? {
        guard let responsibleForPid else { return nil }
        let owner = responsibleForPid(pid)
        // A process is usually responsible for itself, which answers nothing.
        return owner > 0 && owner != pid ? owner : nil
    }

    private static func processTable() -> [pid_t: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, 4, nil, &length, nil, 0) == 0, length > 0 else { return [:] }

        // The table can grow between being sized and being read, so ask for more than was
        // quoted rather than failing because something launched in between.
        length += length / 8
        var buffer = [kinfo_proc](
            repeating: kinfo_proc(), count: length / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &buffer, &length, nil, 0) == 0 else { return [:] }

        var names: [pid_t: String] = [:]
        for entry in buffer.prefix(length / MemoryLayout<kinfo_proc>.stride) {
            var process = entry.kp_proc
            let name = withUnsafePointer(to: &process.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if process.p_pid > 0, !name.isEmpty { names[process.p_pid] = name }
        }
        return names
    }

    /// Nanoseconds of CPU each process has burned, for the ones that will say. A process that
    /// refuses is skipped rather than recorded as zero -- unreadable is not idle.
    private static func cpuTimes(of pids: [pid_t]) -> [pid_t: UInt64] {
        var times: [pid_t: UInt64] = [:]
        for pid in pids {
            var info = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result == 0 else { continue }
            times[pid] = info.ri_user_time + info.ri_system_time
        }
        return times
    }

    /// The largest resident process, named and sized: `Obsidian 2.4 GB`.
    ///
    /// Deliberately the biggest consumer rather than whoever grew most in the last second. A
    /// surge of a couple of gigabytes takes longer than any sampling window worth waiting on,
    /// and by the time the alert fires the growth is usually over -- differencing two readings
    /// would then name nobody at all. The biggest process is the honest answer to "what should
    /// I look at first", and the notch is not claiming it caused the jump.
    @objc func topMemoryProcess(with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let names = Self.processTable()
            var heaviest: pid_t = 0
            var footprint: UInt64 = 0
            for pid in names.keys {
                var info = rusage_info_current()
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                    }
                }
                guard result == 0, info.ri_phys_footprint > footprint else { continue }
                footprint = info.ri_phys_footprint
                heaviest = pid
            }
            // Under a gigabyte nothing is worth naming: whatever moved memory by that much was
            // not this process.
            guard footprint >= 1_073_741_824, let name = names[heaviest] else {
                reply(nil)
                return
            }
            let gigabytes = Double(footprint) / 1_073_741_824
            reply(String(format: "%@ %.1f GB", Self.displayName(of: heaviest, fallback: name), gigabytes))
        }
    }

    /// The process drawing the most power, named and measured: `Python 26.2 W`.
    ///
    /// `ri_energy_nj` and `ri_penergy_nj` are the kernel's own per-process energy accounting in
    /// nanojoules, split across E-cores and P-cores. They are counters since the process
    /// started, so like CPU time a single reading only says which process has existed longest.
    /// Two readings differenced by a wall clock give watts, and the units cancel exactly:
    /// nanojoules over nanoseconds *is* watts, with no scale factor to get wrong. That is the
    /// one pleasant difference from `busiestProcess`, which needs the mach timebase.
    ///
    /// This is the only attribution that still works on mains power. `drain` reads the
    /// battery and therefore has nothing to say with the cable in, but "why is the fan loud"
    /// is the same question, and the answer is in the same counter.
    @objc func topPowerProcess(with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(Self.hungriestProcess())
        }
    }

    private static func hungriestProcess(over interval: TimeInterval = 0.3) -> String? {
        let names = processTable()
        guard !names.isEmpty else { return nil }

        let pids = Array(names.keys)
        let first = energyNanojoules(of: pids)
        guard !first.isEmpty else { return nil }

        let started = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: interval)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started)
        guard elapsed > 0 else { return nil }

        var hungriest: pid_t = 0
        var watts = 0.0
        for (pid, after) in energyNanojoules(of: pids) {
            guard let before = first[pid], after > before else { continue }
            let draw = Double(after - before) / elapsed
            if draw > watts { watts = draw; hungriest = pid }
        }
        // Half a watt. Measured on this machine at rest the whole user session attributes
        // about 1.5 W across a hundred processes, so anything under this is the noise floor
        // and naming the largest grain of it would be a confident wrong answer.
        guard watts >= 0.5, let name = names[hungriest] else { return nil }
        return String(format: "%@ %.1f W", displayName(of: hungriest, fallback: name), watts)
    }

    /// Nanojoules burned per process, for the ones that will say. `&+` because these are two
    /// independent free-running counters and a wrap must not trap the helper.
    private static func energyNanojoules(of pids: [pid_t]) -> [pid_t: UInt64] {
        var energy: [pid_t: UInt64] = [:]
        for pid in pids {
            var info = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result == 0 else { continue }
            energy[pid] = info.ri_energy_nj &+ info.ri_penergy_nj
        }
        return energy
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }

    /// Cmd-V into whatever has focus. Here, not in the app: the sandbox cannot post events,
    /// and Accessibility trust lives on this process. `keyCode` is the key that types V on
    /// the active layout, found by the app (PasteKeycode).
    @objc func postPasteKeystroke(_ keyCode: Int, with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(), (0...127).contains(keyCode) else { return reply(false) }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        else { return reply(false) }
        down.flags = .maskCommand   // explicit: never inherit whatever modifiers are still physically held
        up.flags = .maskCommand
        Self.tag(down)
        Self.tag(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        reply(true)
    }
    
    /// Focused text field for the ghost-text feature. Here because only this process holds Accessibility trust.
    @objc func focusedTextSnapshot(with reply: @escaping (String?) -> Void) {
        reply(FocusedTextReader.snapshotJSON())
    }

    /// Inserts ghost text at `location`, the caret the app read, and only if GhostInsertCheck still allows it.
    /// Replies: 0 inserted, 2 set failed (typed instead, 7), 3 unverified, 4 no focus, 5 refused, 6 not trusted, 7 typed fallback.
    @objc func ghostInsert(_ location: Int, _ text: String, with reply: @escaping (Int) -> Void) {
        guard AXIsProcessTrusted() else { return reply(6) }
        guard let element = Self.currentFocusedElement() else { return reply(4) }
        let result = GhostInsertCheck.insert(text, at: location, into: AXGhostField(element: element))
        var settable: DarwinBoolean = true
        let canSet = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        if result == .setFailed && !canSet {
            // Only when the attribute is definitively not settable; a settable-but-failed set may have written.
            // Already tagged, flags empty. Never reached after .unverified, which would double-insert.
            Self.typeUnicode(text)
            return reply(7)
        }
        reply(result.rawValue)
    }

    /// The focused AX field as a GhostTextField. It reads and sets only the selection and the text around it.
    private struct AXGhostField: GhostTextField {
        let element: AXUIElement

        var selection: (location: Int, length: Int)? {
            guard let range = BoringNotchXPCHelper.selectedRange(element) else { return nil }
            return (Int(range.location), Int(range.length))
        }

        var value: String? {
            BoringNotchXPCHelper.copyString(element, kAXValueAttribute as String)
        }

        func setSelectedText(_ text: String) -> Bool {
            BoringNotchXPCHelper.setString(element, kAXSelectedTextAttribute as String, text)
        }

        func string(location: Int, length: Int) -> String? {
            BoringNotchXPCHelper.string(in: element, location, length)
        }
    }
    

    // MARK: - Dictation rewrite (U4)

    /// Chromium and Electron apps build their accessibility tree only on request. Turns it on for `pid` when the
    /// system-wide focus cannot be read for that app, and remembers `pid` for the take. Never touches other apps.
    @objc func prepareFocus(_ pid: Int, with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(), pid > 0 else { return reply(false) }
        Self.restoreManualAccessibility()
        Self.preparedPid = pid_t(pid)
        var systemFocusPid: pid_t = 0
        if let focused = Self.copyValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String) {
            AXUIElementGetPid(focused as! AXUIElement, &systemFocusPid)
        }
        if systemFocusPid != pid_t(pid) {
            let app = AXUIElementCreateApplication(pid_t(pid))
            if (Self.copyValue(app, "AXManualAccessibility") as? Bool) != true {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                Self.manualAXPid = pid_t(pid)
            }
        }
        reply(Self.currentFocusedElement() != nil)
    }

    /// The strict key from ~/.config/openrouter-key, and only that file. Never logged.
    @objc func openRouterKey(with reply: @escaping (String?) -> Void) {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let path = (home as NSString).appendingPathComponent(".config/openrouter-key")
        let key = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        reply(key.flatMap { $0.isEmpty ? nil : $0 })
    }

    @objc func focusedTextValue(with reply: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted(), let element = Self.currentFocusedElement() else { return reply(nil) }
        if Self.copyString(element, kAXRoleAttribute as String) == "AXSecureTextField"
            || Self.copyString(element, kAXSubroleAttribute as String) == "AXSecureTextField" { return reply(nil) }
        guard let value = Self.copyString(element, kAXValueAttribute as String), value.count <= 20_000 else {
            return reply(nil)
        }
        reply(value)
    }

    @objc func beginTracking(with reply: @escaping (String?) -> Void) {
        trackedElement = nil
        guard AXIsProcessTrusted(), let element = Self.currentFocusedElement() else { return reply(nil) }
        trackedElement = element
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let role = Self.copyString(element, kAXRoleAttribute as String) ?? ""
        let subrole = Self.copyString(element, kAXSubroleAttribute as String) ?? ""
        let bundle: Any = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? NSNull()
        let field: [String: Any] = [
            "pid": Int(pid),
            "bundle": bundle,
            "role": role,
            "secure": role == "AXSecureTextField" || subrole == "AXSecureTextField",
            "caret": Self.selectedRange(element)?.location ?? -1,
            "rangeSettable": Self.isSettable(element, kAXSelectedTextRangeAttribute as String),
            "textSettable": Self.isSettable(element, kAXSelectedTextAttribute as String),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: field),
              let json = String(data: data, encoding: .utf8) else { return reply(nil) }
        reply(json)
    }

    @objc func caretLocation(with reply: @escaping (Int) -> Void) {
        guard AXIsProcessTrusted() else { return reply(-1) }
        guard let element = trackedFocus() else { return reply(-2) }
        reply(Self.selectedRange(element)?.location ?? -1)
    }

    @objc func stringForRange(_ location: Int, _ length: Int, with reply: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted(), let element = trackedFocus() else { return reply(nil) }
        reply(Self.string(in: element, location, length))
    }

    /// Sets the range, then the selected text, then verifies the span. Codes: 0 ok, 1 selectFailed,
    /// 2 setFailed, 3 verifyMismatch, 4 noFocus, 5 focusMoved, 6 notTrusted. 1, 2, 4, 5, 6 change nothing.
    @objc func axReplace(_ location: Int, _ length: Int, _ text: String, with reply: @escaping (Int) -> Void) {
        guard AXIsProcessTrusted() else { return reply(6) }
        guard let element = trackedFocus() else { return reply(unavailableCode()) }
        guard Self.setRange(element, location, length) else { return reply(1) }
        guard Self.setString(element, kAXSelectedTextAttribute as String, text) else { return reply(2) }
        guard Self.string(in: element, location, text.utf16.count) == text else { return reply(3) }
        _ = Self.setRange(element, location + text.utf16.count, 0)
        reply(0)
    }

    /// Selects the span, checks the selection took, types the new text as real key events, then puts the
    /// caret at `caretAfter`. A caret failure after typing reports 3, because the text has already changed.
    @objc func axSelectThenType(_ location: Int, _ length: Int, _ text: String, _ caretAfter: Int,
                                with reply: @escaping (Int) -> Void) {
        guard AXIsProcessTrusted() else { return reply(6) }
        guard let element = trackedFocus() else { return reply(unavailableCode()) }
        guard Self.setRange(element, location, length),
              let readBack = Self.selectedRange(element),
              readBack.location == location, readBack.length == length else { return reply(1) }
        // An empty replacement types nothing, so a pure deletion is a Delete over the selection.
        if text.isEmpty {
            if length > 0 { Self.postKey(51, flags: []) }
        } else {
            Self.typeUnicode(text)
        }
        reply(Self.setRange(element, caretAfter, 0) ? 0 : 3)
    }

    /// Keyboard-only swap for apps where the selection cannot be set: caret is at the span end, so go left
    /// over the suffix, select the old middle with shift+left, type over it, and return to the span end.
    @objc func typeSwap(_ suffixGraphemes: Int, _ oldGraphemes: Int, _ text: String,
                        with reply: @escaping (Int) -> Void) {
        guard AXIsProcessTrusted() else { return reply(6) }
        guard trackedFocus() != nil else { return reply(unavailableCode()) }
        for _ in 0..<max(0, suffixGraphemes) { Self.postKey(123, flags: []) }
        for _ in 0..<max(0, oldGraphemes) { Self.postKey(123, flags: .maskShift) }
        // An empty replacement types nothing, so a pure deletion is a Delete over the selection.
        if text.isEmpty {
            if oldGraphemes > 0 { Self.postKey(51, flags: []) }
        } else {
            Self.typeUnicode(text)
        }
        for _ in 0..<max(0, suffixGraphemes) { Self.postKey(124, flags: []) }
        reply(0)
    }

    @objc func endTracking() {
        trackedElement = nil
        Self.restoreManualAccessibility()
        Self.preparedPid = 0
    }

    /// Turns AXManualAccessibility back off on the app this helper turned it on for.
    private static func restoreManualAccessibility() {
        if manualAXPid > 0 {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(manualAXPid), "AXManualAccessibility" as CFString,
                                         kCFBooleanFalse)
            manualAXPid = 0
        }
    }

    /// The tracked element while it still has focus, or nil.
    private func trackedFocus() -> AXUIElement? {
        guard let tracked = trackedElement, let focused = Self.currentFocusedElement(),
              CFEqual(focused, tracked) else { return nil }
        return tracked
    }

    /// 4 when nothing is tracked, 5 when focus has moved away.
    private func unavailableCode() -> Int {
        trackedElement == nil ? 4 : 5
    }

    /// The system-wide focus. Falls back to the prepared app's own focus, but only while that app is frontmost:
    /// typeSwap posts keys to the frontmost app, so a background app's element must never be returned.
    private static func currentFocusedElement() -> AXUIElement? {
        if let ref = copyValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String) {
            return (ref as! AXUIElement)
        }
        guard preparedPid > 0,
              (copyValue(AXUIElementCreateApplication(preparedPid), kAXFrontmostAttribute as String) as? Bool) == true,
              let ref = copyValue(AXUIElementCreateApplication(preparedPid), kAXFocusedUIElementAttribute as String)
        else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let ref = copyValue(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func setRange(_ element: AXUIElement, _ location: Int, _ length: Int) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func setString(_ element: AXUIElement, _ attribute: String, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, text as CFString) == .success
    }

    private static func string(in element: AXUIElement, _ location: Int, _ length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    /// Arrow keys and shift+arrow, as tagged events the app's own tap ignores.
    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        tag(down)
        tag(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Types unicode in chunks of at most 20 UTF-16 units, never splitting a surrogate pair.
    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count, end - 1 > start, (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }
            let chunk = Array(units[start..<end])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                tag(event)
                event.post(tap: .cgSessionEventTap)
            }
            start = end
        }
    }

    /// Every synthesized event carries the dictation tag, so the app's tap ignores it.
    private static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: DictationEvents.tag)
    }

    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

// MARK: - Panels

extension BoringNotchXPCHelper {
    /// The full CPU/memory ranking. `busiestProcess` already builds this and throws all but
    /// the winner away, so this is the same two-reading measurement kept whole.
    @objc func topProcesses(_ limit: Int, with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let names = Self.processTable()
            guard !names.isEmpty else { return reply(nil) }

            let pids = Array(names.keys)
            let first = Self.cpuTimes(of: pids)
            guard !first.isEmpty else { return reply(nil) }

            // A single reading cannot answer "what is busy now" — `proc_pid_rusage` reports
            // CPU burned since launch, so a long-lived idle process would always win.
            let started = DispatchTime.now().uptimeNanoseconds
            Thread.sleep(forTimeInterval: 0.3)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started)
            guard elapsed > 0 else { return reply(nil) }

            let second = Self.cpuTimes(of: Array(first.keys))
            var rows: [[String: Any]] = []
            for (pid, after) in second {
                guard let before = first[pid], after > before, let name = names[pid] else { continue }
                var memory: UInt64 = 0
                var info = rusage_info_current()
                withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        _ = proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                    }
                }
                memory = info.ri_resident_size
                rows.append([
                    "name": name,
                    "cpu": Double(after - before) / elapsed,
                    "mem": memory,
                ])
            }
            rows.sort { ($0["cpu"] as? Double ?? 0) > ($1["cpu"] as? Double ?? 0) }
            let top = Array(rows.prefix(max(0, limit)))
            guard let data = try? JSONSerialization.data(withJSONObject: top) else { return reply(nil) }
            reply(String(data: data, encoding: .utf8))
        }
    }

    /// Whitelisted, never argv passthrough. This service is `ServiceType: Application` and so
    /// is private to the containing bundle, which makes this defence in depth — but it is one
    /// switch, and it means a future bug in the app cannot become arbitrary execution.
    @objc func runTailscale(_ subcommand: String, with reply: @escaping (String?) -> Void) {
        let arguments: [String]
        switch subcommand {
        case "status": arguments = ["status", "--json"]
        case "up": arguments = ["up"]
        case "down": arguments = ["down"]
        default: return reply(nil)
        }

        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return reply(nil) }

        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: binary)
            task.arguments = arguments
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return reply(nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            reply(String(data: data, encoding: .utf8))
        }
    }

    /// Battery for classic-Bluetooth devices, as `system_profiler`'s own JSON.
    ///
    /// Here rather than in the app for the same reason as `runTailscale`: spawning a process
    /// is not something the sandbox permits. Measured at ~40 ms of CPU per call, which is why
    /// the caller asks only when the set of connected devices changes or the panel is open,
    /// and never on the five-second watch tick.
    @objc func bluetoothDevices(with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            task.arguments = ["-json", "SPBluetoothDataType"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return reply(nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            reply(String(data: data, encoding: .utf8))
        }
    }
}
