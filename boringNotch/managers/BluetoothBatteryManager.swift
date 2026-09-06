//
//  BluetoothBatteryManager.swift
//  boringNotch
//
//  Battery levels for connected Bluetooth devices.
//
//  Read over the **standard GATT Battery Service** (`0x180F`, characteristic `0x2A19`)
//  through CoreBluetooth, which is public API and works on every device that implements
//  the spec.
//
//  This is deliberately *not* the approach upstream's PR #1376 takes, and the difference
//  was measured rather than assumed. That PR reads undocumented `BatteryPercent*` keys from
//  `AppleDeviceManagementHIDEventService` and watches classic-Bluetooth connect
//  notifications via `IOBluetoothDevice`. With an MX Master 3S connected on this machine,
//  the whole IOKit path returns nothing: no `BatteryPercent` key exists anywhere in the
//  registry, and the mouse does not appear in the registry at all. The reason is in
//  `system_profiler`: `device_services = 0x400000 < BLE >`. It is a Low Energy device, and
//  both halves of that approach are classic-Bluetooth only.
//
//  CoreBluetooth read the same mouse at 55% first try.
//
//  The trade is that `0x2A19` is a single byte, so it cannot express the left / right / case
//  split that AirPods report. Those three values are Apple-proprietary and do come from the
//  IOKit registry -- so that path is still worth adding later as an *enrichment* for Apple
//  devices, layered on top of this. It is not the foundation.
//

import Combine
import CoreBluetooth
import Foundation
import OSLog

/// Survives Release, unlike `debugLog`. OSLog redacts interpolated values as `<private>`
/// by default, so device names never reach the system log -- only the counts and states
/// needed to tell "no devices" apart from "never asked" apart from "asked and refused".
///
/// `.notice`, not `.info`: info-level messages are kept in a memory ring and never written
/// to the log store, so `log show` finds nothing afterwards and the whole point of having
/// diagnostics in a Release build is lost.
private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "BluetoothBattery")

/// A trace that can actually be read back.
///
/// `log show` returns nothing whatsoever for this process -- not for `.notice`, not during a
/// launch crash, not for any predicate -- so two rounds of "the log is empty, therefore the
/// code never ran" were conclusions drawn from a broken instrument. A file in the sandbox
/// container cannot fail that way.
///
/// Names are written; this file lives inside the app's own container and is never
/// transmitted. It is capped so it cannot grow without bound.
func btTrace(_ line: String) {
    // Debug builds only. This was the instrument that found both bugs -- `log show` returns
    // nothing whatsoever for this process, so a file in the container was the only channel
    // that worked -- but it writes Bluetooth device *names* to disk, and a shipping build
    // has no business doing that for a problem that is now fixed. Same rule as `debugLog`.
    #if !DEBUG
    return
    #else
    guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }
    let url = dir.appendingPathComponent("bt-trace.log")
    let stamped = ISO8601DateFormatter().string(from: Date()) + "  " + line + "\n"
    guard let data = stamped.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        if (try? handle.seekToEnd()).map({ $0 > 64_000 }) == true {
            try? handle.truncate(atOffset: 0)
        }
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
    #endif
}

@MainActor
final class BluetoothBatteryManager: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let percent: Int
        /// Charge over the session, oldest first, as a 0...1 fraction. Polled once a minute,
        /// so this fills in slowly and honestly rather than being interpolated into a curve.
        var history: [Double] = []

        /// Where this device's charge was when it was first seen, and when that was.
        var firstPercent: Int = 0
        var firstSeen: Date = .now

        /// Percentage points per hour, negative while draining.
        ///
        /// `nil` until there is enough elapsed time to mean anything. GATT gives a level and
        /// nothing else -- there is no wattage to read from a mouse -- so a rate can only be
        /// measured by watching, and fifteen minutes is the earliest a one-point-per-minute
        /// integer reading says more than rounding does.
        var drainPerHour: Double? {
            let hours = Date.now.timeIntervalSince(firstSeen) / 3600
            guard hours >= 0.25 else { return nil }
            let delta = Double(percent - firstPercent)
            guard delta != 0 else { return nil }
            return delta / hours
        }
    }

    static let shared = BluetoothBatteryManager()

    /// Sorted by name so the row does not reshuffle itself between refreshes. Published,
    /// unlike the spectrum's levels: a battery changes a few times an hour, so there is no
    /// 30 Hz invalidation problem to design around here.
    @Published private(set) var devices: [Device] = []

    /// Whether Bluetooth is available and permitted at all. The strip uses it to leave the
    /// page out entirely rather than draw an empty row.
    @Published private(set) var isAvailable = false

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    /// Battery moves slowly. A minute is frequent enough to be current and rare enough that
    /// the radio work is invisible.
    private static let refreshInterval: TimeInterval = 60

    private var central: CBCentralManager?
    private var refreshTimer: Timer?

    /// Peripherals are held only for the duration of a read. CoreBluetooth does not retain
    /// them for you -- a `CBPeripheral` that goes out of scope mid-connect simply never
    /// calls back -- but holding them *past* the read would keep a link open for nothing.
    private var reading: [UUID: CBPeripheral] = [:]
    private var collected: [UUID: Device] = [:]

    /// What was connected at the last poll, so appearing and disappearing are both news.
    private var announced: Set<UUID> = []
    /// Devices connected but not yet read, whose activity is waiting on a charge figure.
    private var pendingAnnounce: Set<UUID> = []

    /// Set once the first poll has taken stock. Distinguishes "nothing connected yet" from
    /// "we have not looked", which an empty set alone cannot.
    private var adopted = false

    /// Disconnects we caused ourselves. `finish` cancels the link after every read, which
    /// lands in `didDisconnectPeripheral` exactly like a device walking away -- so without
    /// this the reads would announce themselves as disconnections.
    private var selfCancelled: Set<UUID> = []

    /// Names outlive readings on purpose. `collected` is pruned the moment a device drops,
    /// which is the same moment the disconnect needs its name -- and falling back to
    /// "Bluetooth device" produced an activity that said "Bluetooth" twice and truncated.
    private var names: [UUID: String] = [:]

    /// Same discipline as every other timer in this app: the strip is the only consumer, it
    /// exists only while the notch is open, and a closed notch must cost nothing. Reference
    /// counted because two views may subscribe at once.
    private var subscribers = 0

    /// The always-on half. Announcing "a device connected" only while the notch happens to be
    /// open is not announcing it, so knowing *which* devices are connected runs all the time
    /// -- it is a lookup against state CoreBluetooth already holds, with no scanning and no
    /// GATT traffic. The expensive half, reading each battery, still runs only while the
    /// strip is on screen.
    private var watchTimer: Timer?
    private static let watchInterval: TimeInterval = 5

    private override init() { super.init() }

    /// Called once at launch. Safe to do here because Bluetooth permission has already been
    /// granted by this point in the app's life for anyone who uses the feature; the first
    /// launch after installing still only prompts once.
    func beginWatching() {
        guard watchTimer == nil else { return }
        btTrace("beginWatching")
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
        let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    /// Which devices are connected right now, and announce anything new. No connecting, no
    /// reading -- this is a query against CoreBluetooth's own bookkeeping.
    private func poll() {
        guard let central, central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        let ids = Set(connected.map(\.identifier))
        for peripheral in connected {
            if let name = peripheral.name { names[peripheral.identifier] = name }
        }

        if !adopted {
            // First look of the session: take what is already connected without announcing
            // it, or launching the app would announce every device already in use.
            adopted = true
        } else {
            for peripheral in connected where !announced.contains(peripheral.identifier) {
                btTrace("connected: \(peripheral.name ?? "unnamed")")
                if let name = peripheral.name { names[peripheral.identifier] = name }
                if let known = collected[peripheral.identifier]?.percent {
                    ConnectionActivityManager.shared.announceBluetooth(
                        name: peripheral.name ?? "Bluetooth device",
                        percent: known, connected: true)
                } else {
                    // Announce once the charge is known rather than immediately. A device
                    // that has just connected has never been read, so announcing now meant
                    // the activity slid to an empty second beat -- the "55% charged" that
                    // never appeared. The read takes a few hundred milliseconds; the
                    // announcement is worth that much more than it is worth being instant.
                    pendingAnnounce.insert(peripheral.identifier)
                }
            }
            for gone in announced.subtracting(ids) {
                let name = collected[gone]?.name ?? names[gone] ?? "Bluetooth device"
                btTrace("disconnected: \(name)")
                ConnectionActivityManager.shared.announceBluetooth(
                    name: name, percent: nil, connected: false)
            }
        }
        announced = ids

        // A device that is genuinely gone leaves the row -- decided here, against the
        // system's own list, rather than off the back of our own post-read disconnect.
        let stale = Set(collected.keys).subtracting(ids)
        if !stale.isEmpty {
            for id in stale { collected.removeValue(forKey: id) }
            devices = collected.values.sorted { $0.name < $1.name }
        }

        // Read now if anything is waiting to be announced, even with the notch shut: it is
        // one read, and it is the difference between naming a charge and not.
        if subscribers > 0 || !pendingAnnounce.isEmpty { refresh() }
    }

    func start() {
        subscribers += 1

        // Created lazily: constructing a CBCentralManager is what triggers the Bluetooth
        // permission prompt, and asking on launch for a page the user may never open is
        // the kind of thing that gets an app denied by reflex.
        btTrace("start, subscribers now \(subscribers)")
        if central == nil {
            logger.notice("creating central manager")
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            // Refresh on *every* open, not only the first subscriber's. SwiftUI pairs
            // onAppear/onDisappear more often than the notch is actually opened, and the
            // first version only ever looked once.
            refresh()
        }
        guard subscribers == 1 else { return }

        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }

        refreshTimer?.invalidate()
        refreshTimer = nil

        // Deliberately *not* cancelling reads that are already in flight. A GATT read takes
        // a few hundred milliseconds and each one disconnects itself in `finish`; killing
        // them here meant a notch opened and closed quickly never completed a single read,
        // which is exactly how this page came up empty with two devices connected.
    }

    private func refresh() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            logger.notice("refresh skipped, central state \(central.state.rawValue, privacy: .public)")
            btTrace("refresh skipped, central state \(central.state.rawValue)")
            return
        }

        // Only devices the *system* already has connected, and only those advertising the
        // battery service. This is a lookup, not a scan: no discovery, no radio sweep, and
        // nothing that could interfere with an audio link.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        logger.notice("retrieveConnectedPeripherals returned \(connected.count, privacy: .public)")
        btTrace("retrieveConnectedPeripherals -> \(connected.count): \(connected.map { $0.name ?? "?" }.joined(separator: ", "))")
        for peripheral in connected {
            guard reading[peripheral.identifier] == nil else { continue }
            reading[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    /// Publish once a read finishes, and drop the link immediately.
    private func finish(_ peripheral: CBPeripheral, percent: Int?) {
        if let percent, let name = peripheral.name, !name.isEmpty {
            let existing = collected[peripheral.identifier]
            var history = existing?.history ?? []
            history.append(Double(percent) / 100)
            if history.count > 60 { history.removeFirst(history.count - 60) }
            collected[peripheral.identifier] = Device(
                id: peripheral.identifier, name: name, percent: percent, history: history,
                firstPercent: existing?.firstPercent ?? percent,
                firstSeen: existing?.firstSeen ?? .now)
        }
        selfCancelled.insert(peripheral.identifier)
        central?.cancelPeripheralConnection(peripheral)
        reading.removeValue(forKey: peripheral.identifier)

        let next = collected.values.sorted { $0.name < $1.name }
        logger.notice("read finished, percent \(percent ?? -1, privacy: .public), devices now \(next.count, privacy: .public)")
        btTrace("read \(peripheral.name ?? "?") -> \(percent.map(String.init) ?? "nil"), devices now \(next.count)")

        if pendingAnnounce.remove(peripheral.identifier) != nil {
            ConnectionActivityManager.shared.announceBluetooth(
                name: peripheral.name ?? names[peripheral.identifier] ?? "Bluetooth device",
                percent: percent, connected: true)
        }

        if next != devices { devices = next }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothBatteryManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        MainActor.assumeIsolated {
            isAvailable = manager.state == .poweredOn
            logger.notice("central state \(manager.state.rawValue, privacy: .public)")
            btTrace("central state \(manager.state.rawValue) (5 == poweredOn, 3 == unauthorized)")
            guard manager.state == .poweredOn else {
                // Powered off, unauthorised or unsupported. Forget what we had rather than
                // show a number that has stopped being true.
                collected.removeAll()
                reading.removeAll()
                if !devices.isEmpty { devices = [] }
                return
            }
            refresh()
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    nonisolated func centralManager(
        _ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated {
            logger.error("connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            finish(peripheral, percent: nil)
        }
    }

    nonisolated func centralManager(
        _ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated {
            reading.removeValue(forKey: peripheral.identifier)
            if selfCancelled.remove(peripheral.identifier) == nil {
                // Not ours: the device actually went away. Polling every five seconds meant
                // up to five seconds of "it already unpaired and the notch has not noticed",
                // which reads as broken. The event itself is immediate.
                btTrace("disconnect event: \(names[peripheral.identifier] ?? "?")")
                poll()
            }
            // Deliberately does *not* drop the reading.
            //
            // This is the bug that made the page look empty. `finish` reads the battery and
            // then calls `cancelPeripheralConnection`, which lands right here -- so every
            // successful read immediately deleted itself, and the trace showed two devices
            // read and "devices now 1" both times. A GATT read that has completed is not a
            // device going away; it is the read working exactly as designed.
            //
            // Whether a device is still *connected* is now decided in `poll`, against
            // CoreBluetooth's own list, which is the only thing that actually knows.
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothBatteryManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            MainActor.assumeIsolated { finish(peripheral, percent: nil) }
            return
        }
        for service in services where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else {
            MainActor.assumeIsolated { finish(peripheral, percent: nil) }
            return
        }
        for characteristic in characteristics where characteristic.uuid == Self.batteryLevel {
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        // One unsigned byte, 0...100 by the spec. Clamped anyway -- this is a number from
        // someone else's firmware, and a 255 would otherwise draw a gauge off the end of
        // the row.
        let percent = characteristic.value?.first.map { Int(min($0, 100)) }
        MainActor.assumeIsolated { finish(peripheral, percent: error == nil ? percent : nil) }
    }
}
