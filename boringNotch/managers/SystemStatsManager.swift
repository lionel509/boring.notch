//
//  SystemStatsManager.swift
//  boringNotch
//
//  Live CPU / memory / network figures for the notch's bottom strip.
//

import Combine
import Darwin
import Foundation

/// Samples aggregate system load, cheaply, and only while something is watching.
///
/// Deliberately not built on `top` or `ps`. Measured on this machine: `top -l 2 -n 0`
/// costs ~280 ms of CPU per sample and `ps aux` ~50 ms, because both enumerate every
/// process — and `top` also redraws a terminal. The Mach calls below cost **6.7 µs** for
/// a paired sample, roughly 42,000× less, because they read aggregate kernel counters and
/// never build a process list. A stats readout does not need per-process data, so it
/// should never pay for it.
///
/// The other half of the cost story is lifecycle. `start()` runs when the strip appears
/// and `stop()` when it disappears, so a closed notch samples nothing at all. The stored
/// timer / re-entry guard / invalidate-on-disappear shape is not incidental — it is the
/// pattern this codebase paid 31.7% idle CPU to learn from the leaked blink timers in
/// `AnimatedFace`.
@MainActor
final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()

    /// Fraction of total CPU capacity in use across all cores, 0...1.
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    @Published private(set) var networkDownBytesPerSec: Double = 0
    @Published private(set) var networkUpBytesPerSec: Double = 0

    let memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// Recent history for the sparklines, oldest first, each value already normalised to
    /// 0...1 so the view never has to know the units. Twelve points is the reference
    /// length for a stat-tile trend and it is all that fits in ~22 pt of width.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var networkDownHistory: [Double] = []
    @Published private(set) var networkUpHistory: [Double] = []

    static let historyLength = 12

    /// Throughput has no ceiling, so the network sparkline scales against the largest
    /// rate seen recently rather than an invented maximum. Decays so one burst does not
    /// flatten the trace for the rest of the session.
    private var networkPeak: Double = 1

    private var timer: Timer?
    private var watchers = 0
    private var previousCPUTicks: (busy: UInt64, total: UInt64)?
    private var previousNetwork: (received: UInt64, sent: UInt64, at: Date)?

    private init() {}

    // MARK: - Lifecycle

    /// Reference counted, so one view disappearing cannot silence another that still
    /// wants figures. Cheap to call repeatedly.
    func start() {
        watchers += 1
        guard timer == nil else { return }

        sample()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // .common so the row keeps ticking while a scroll or drag is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }

        timer?.invalidate()
        timer = nil
        // Drop the baselines too: a stale one would make the first sample after
        // reopening report the average since the notch was last closed.
        previousCPUTicks = nil
        previousNetwork = nil
        cpuHistory = []
        memoryHistory = []
        networkDownHistory = []
        networkUpHistory = []
        networkPeak = 1
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
        recordHistory()
    }

    private func recordHistory() {
        func push(_ value: Double, into history: inout [Double]) {
            history.append(min(max(value, 0), 1))
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }

        push(cpuUsage, into: &cpuHistory)
        push(memoryFraction, into: &memoryHistory)

        // Down and up share one ceiling. They are small multiples of the same measure, so
        // giving each its own scale would draw a trickle of upload at the same height as a
        // saturated download. Each cell prints its own figure, so nothing is lost by the
        // quieter direction sitting low in its plot — that is the true shape.
        networkPeak = max(networkDownBytesPerSec, networkUpBytesPerSec, networkPeak * 0.92, 1)
        push(networkDownBytesPerSec / networkPeak, into: &networkDownHistory)
        push(networkUpBytesPerSec / networkPeak, into: &networkUpHistory)
    }

    var memoryFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    // MARK: - CPU

    private func sampleCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // cpu_ticks is indexed by CPU_STATE_USER / SYSTEM / IDLE / NICE.
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let total = busy + UInt64(info.cpu_ticks.2)

        defer { previousCPUTicks = (busy, total) }
        // These are monotonic counters, so the first sample only establishes a baseline.
        guard let previous = previousCPUTicks else { return }

        let busyDelta = Double(busy &- previous.busy)
        let totalDelta = Double(total &- previous.total)
        guard totalDelta > 0 else { return }

        cpuUsage = min(max(busyDelta / totalDelta, 0), 1)
    }

    // MARK: - Memory

    private func sampleMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // Activity Monitor's "Memory Used" is app memory + wired + compressed, which maps
        // to active + wired + compressor pages. Inactive and speculative pages are
        // reclaimable on demand; counting them would report a permanently full machine.
        let pages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)

        memoryUsedBytes = pages * UInt64(vm_page_size)
    }

    // MARK: - Network

    private func sampleNetwork() {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            // AF_LINK entries are the ones carrying byte counters.
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            // Loopback is real traffic to the kernel but not to the network, and on a
            // busy machine it dwarfs the number anyone wants to read.
            guard interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }

            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previous = previousNetwork else { return }

        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return }

        networkDownBytesPerSec = Double(received &- previous.received) / elapsed
        networkUpBytesPerSec = Double(sent &- previous.sent) / elapsed
    }
}
