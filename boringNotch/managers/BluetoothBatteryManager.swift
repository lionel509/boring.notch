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
private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "BluetoothBattery")

@MainActor
final class BluetoothBatteryManager: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let percent: Int
        /// Charge over the session, oldest first, as a 0...1 fraction. Polled once a minute,
        /// so this fills in slowly and honestly rather than being interpolated into a curve.
        var history: [Double] = []
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

    /// Devices already announced this session, so a reconnect is news and a refresh is not.
    private var announced: Set<UUID> = []

    /// Same discipline as every other timer in this app: the strip is the only consumer, it
    /// exists only while the notch is open, and a closed notch must cost nothing. Reference
    /// counted because two views may subscribe at once.
    private var subscribers = 0

    private override init() { super.init() }

    func start() {
        subscribers += 1

        // Created lazily: constructing a CBCentralManager is what triggers the Bluetooth
        // permission prompt, and asking on launch for a page the user may never open is
        // the kind of thing that gets an app denied by reflex.
        if central == nil {
            logger.info("creating central manager")
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
            logger.info("refresh skipped, central state \(central.state.rawValue, privacy: .public)")
            return
        }

        // Only devices the *system* already has connected, and only those advertising the
        // battery service. This is a lookup, not a scan: no discovery, no radio sweep, and
        // nothing that could interfere with an audio link.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        logger.info("retrieveConnectedPeripherals returned \(connected.count, privacy: .public)")
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
            var history = collected[peripheral.identifier]?.history ?? []
            history.append(Double(percent) / 100)
            if history.count > 60 { history.removeFirst(history.count - 60) }
            collected[peripheral.identifier] = Device(
                id: peripheral.identifier, name: name, percent: percent, history: history)
        }
        central?.cancelPeripheralConnection(peripheral)
        reading.removeValue(forKey: peripheral.identifier)

        let next = collected.values.sorted { $0.name < $1.name }
        logger.info("read finished, percent \(percent ?? -1, privacy: .public), devices now \(next.count, privacy: .public)")

        // Announce a device the notch has not seen before -- but never on the very first
        // read of a session, or opening the notch would fire one activity per device that
        // was already connected before the app started.
        if announced.isEmpty {
            announced = Set(next.map(\.id))
        } else if let fresh = next.first(where: { !announced.contains($0.id) }) {
            announced.insert(fresh.id)
            ConnectionActivityManager.shared.announceBluetooth(name: fresh.name, percent: fresh.percent)
        }

        if next != devices { devices = next }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothBatteryManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        MainActor.assumeIsolated {
            isAvailable = manager.state == .poweredOn
            logger.info("central state \(manager.state.rawValue, privacy: .public)")
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
            // A device that has gone away must leave the row. Otherwise a pocketed mouse
            // sits there at its last value for the rest of the session.
            if collected.removeValue(forKey: peripheral.identifier) != nil {
                devices = collected.values.sorted { $0.name < $1.name }
            }
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
