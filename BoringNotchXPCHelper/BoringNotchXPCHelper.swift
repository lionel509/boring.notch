//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ApplicationServices
import OSLog
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
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
