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
        Logger(subsystem: "theboringteam.boringnotch", category: "SystemAlert").notice("""
            helper: \(second.count, privacy: .public) of \(pids.count, privacy: .public) \
            readable, top \(cores, format: .fixed(precision: 2), privacy: .public) cores = \
            \(names[busiest] ?? "?", privacy: .public)
            """)
        // Below half a core, nobody is to blame. A load spread across forty processes has no
        // culprit, and naming the largest of forty small ones is a confident wrong answer --
        // worse than saying nothing, because the figure beside it makes it look checked.
        guard cores >= 0.5 else { return nil }
        return names[busiest]
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
