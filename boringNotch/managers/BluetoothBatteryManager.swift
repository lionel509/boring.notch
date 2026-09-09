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
import IOBluetooth
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
        /// A peripheral UUID for a Low Energy device, a hardware address for a classic one.
        /// The two sources have no identifier in common -- CoreBluetooth deliberately hides
        /// the MAC -- so this is a string rather than a `UUID`.
        let id: String
        let name: String
        /// For earbuds reporting a left and a right, the *lower* of the two: that is the one
        /// that ends the call. A single figure is what the row has space for, and an average
        /// would read 50% with one bud flat.
        let percent: Int
        /// The per-bud split, when the device reports one. `system_profiler` is the only
        /// source that carries it -- GATT `0x2A19` is a single byte and cannot express three
        /// numbers -- so these are populated for classic Apple earbuds and stay nil for
        /// everything else, the AirPods Max included: one earpiece, as far as its battery
        /// is concerned.
        var left: Int? = nil
        var right: Int? = nil
        /// The case, which reports only while it is awake and in range. It comes and goes
        /// independently of the buds, so it cannot share their cell.
        var caseCharge: Int? = nil

        /// Whether there are two sides worth naming separately. A device reporting only one
        /// of them is drawn as a single figure -- an `L` with no `R` is worse than neither.
        var isSplit: Bool { left != nil && right != nil }

        /// `L95 R94` for earbuds, `95%` for everything else.
        var reading: String {
            if let left, let right { return "L\(left) R\(right)" }
            return "\(percent)%"
        }

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

    // MARK: The other half of the roster -- classic Bluetooth
    //
    // CoreBluetooth cannot see a classic device at all. Measured on this machine with AirPods
    // connected and playing: `retrieveConnectedPeripherals(withServices: [180F])` returns
    // **zero**, because the headphones speak HFP/A2DP rather than GATT. So the page sat empty
    // while a pair of headphones with 82% left sat on his head -- which is the whole of "the
    // notch bluetooth is not working".
    //
    // The battery for those devices exists in exactly one reachable place: `system_profiler`,
    // which reports `device_batteryLevelLeft` / `Right` / `Case`. The other two routes people
    // recommend were both re-measured here and both return nothing at all -- `ioreg -k
    // BatteryPercent` is empty, and `AppleDeviceManagementHIDEventService` contains only the
    // internal keyboard. That settles the "AirPods half is unmeasured" caveat in the spec: the
    // IOKit enrichment path does not work on this machine, and this is what replaces it.

    /// Battery for classic devices, keyed by canonical hardware address.
    private var classic: [String: Device] = [:]
    /// Address -> name for the classic devices connected right now, from IOBluetooth.
    private var classicConnected: [String: String] = [:]
    private var announcedClassic: Set<String> = []
    /// Last raw reading, still awaiting a second opinion. See `pollClassic`.
    private var unconfirmedClassic: Set<String> = []
    private var pendingAnnounceClassic: Set<String> = []
    private var adoptedClassic = false

    /// IOBluetooth answered with a paired device at least once, so it is a usable source.
    ///
    /// It is the cheap half of this: `pairedDevices()` plus `isConnected()` across the whole
    /// roster measures **0.22 ms**, against 40 ms of CPU to spawn `system_profiler`. So
    /// membership is watched in-process every five seconds and the expensive call is made only
    /// when that membership changes, or while the panel is actually on screen.
    ///
    /// If it ever turns out to answer nothing -- it is reached through a sandbox, and this is
    /// the one part of the design that cannot be proven from outside one -- the flag stays
    /// false and the fallback below polls `system_profiler` slowly instead. The feature
    /// degrades to "less prompt" rather than to "gone".
    private var ioBluetoothWorks = false
    /// When a point was last appended to the classic sparklines. The membership poll now
    /// carries the charge, so it arrives every five seconds -- but the trend is meant to show
    /// a session, and 60 points at 5 s would show five minutes. Held to the original cadence.
    private var lastClassicHistory: Date = .distantPast
    private var readingClassic = false
    private var lastClassicRead: Date = .distantPast
    /// Floor between helper calls, so a burst of connect events is still one spawn.
    private static let classicReadFloor: TimeInterval = 3
    /// Cadence when IOBluetooth is unavailable and `system_profiler` is the only source.
    private static let classicFallbackInterval: TimeInterval = 30

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
        pollClassic()
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
            publish()
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

        // The panel is open or the minute is up, so this is the moment the expensive half
        // is worth paying for.
        readClassicBattery()

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
                id: peripheral.identifier.uuidString, name: name, percent: percent, history: history,
                firstPercent: existing?.firstPercent ?? percent,
                firstSeen: existing?.firstSeen ?? .now)
        }
        selfCancelled.insert(peripheral.identifier)
        central?.cancelPeripheralConnection(peripheral)
        reading.removeValue(forKey: peripheral.identifier)

        logger.notice("read finished, percent \(percent ?? -1, privacy: .public), devices now \(self.devices.count, privacy: .public)")
        btTrace("read \(peripheral.name ?? "?") -> \(percent.map(String.init) ?? "nil")")

        if pendingAnnounce.remove(peripheral.identifier) != nil {
            ConnectionActivityManager.shared.announceBluetooth(
                name: peripheral.name ?? names[peripheral.identifier] ?? "Bluetooth device",
                percent: percent, connected: true)
        }

        publish()
    }

    /// The published roster: everything CoreBluetooth read, plus everything `system_profiler`
    /// reported, as one list.
    ///
    /// Deduplicated by name and not by identifier, because the two sources share no identifier
    /// -- and a device that somehow appears in both is one device to the person reading the
    /// row. The classic entry wins that tie: it is the one carrying a left/right split.
    private func publish() {
        var byName: [String: Device] = [:]
        for device in collected.values { byName[device.name.lowercased()] = device }
        for device in classic.values { byName[device.name.lowercased()] = device }
        let next = byName.values.sorted { $0.name < $1.name }
        if next != devices { devices = next }
    }
}

// MARK: - Classic Bluetooth

extension BluetoothBatteryManager {
    /// Who is connected over classic Bluetooth, cheaply.
    ///
    /// `pairedDevices()` and `isConnected()` are an in-process lookup against state the
    /// Bluetooth stack already holds -- 0.22 ms for the whole roster, measured -- so this can
    /// sit on the same five-second tick as the Low Energy watch without costing anything.
    /// Nothing here spawns a process; that only happens when the answer changes.
    private func pollClassic() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        if !paired.isEmpty { ioBluetoothWorks = true }

        guard ioBluetoothWorks else {
            // No cheap membership source to be had. Ask the tool itself, slowly, so the
            // batteries still appear even though connect events will be up to half a minute
            // late. Better a late activity than a permanently empty page.
            if Date.now.timeIntervalSince(lastClassicRead) >= Self.classicFallbackInterval {
                readClassicBattery(force: true)
            }
            return
        }

        var connected: [String: String] = [:]
        var readings: [String: Reading] = [:]
        for device in paired where device.isConnected() {
            guard let address = device.addressString else { continue }
            let id = Self.canonical(address)
            connected[id] = device.name ?? "Bluetooth device"
            if let reading = Self.ioBattery(device) { readings[id] = reading }
        }

        let ids = Set(connected.keys)

        // A membership change has to survive a second poll before it is believed.
        //
        // Measured on this Mac: his headphones connected and dropped again **inside one
        // second** -- 13:40:02 to 13:40:03 -- and then nothing moved for the next four
        // minutes. Continuity keeps links like that up and down all day. A five-second poll
        // lands inside a flap like that maybe a fifth of the time, which is exactly the
        // reported symptom: mostly quiet, then a connect and a disconnect for something
        // nobody touched. One tick of confirmation costs a real connect five seconds and
        // removes the entire class of phantom pairs.
        let settled = ids == unconfirmedClassic
        unconfirmedClassic = ids
        guard settled else { return }

        let changed = ids != Set(classicConnected.keys)
        // Captured before the overwrite: a device that drops needs its name at exactly the
        // moment it stops being listed, and it may never have had a battery read to keep one.
        let previous = classicConnected
        classicConnected = connected

        if !adoptedClassic {
            // First look of the session -- take what is already connected without announcing,
            // or launching would announce the headphones already on his head.
            adoptedClassic = true
        } else if changed {
            for id in ids.subtracting(announcedClassic) {
                btTrace("classic connected: \(connected[id] ?? "?")")
                // Announced once the charge is known, like the Low Energy path: the whole
                // point of this activity is the number, and it arrives ~40 ms later.
                pendingAnnounceClassic.insert(id)
            }
            for gone in announcedClassic.subtracting(ids) {
                // Only for something whose arrival was worth announcing. Symmetric with the
                // charge gate in `applyClassic`, and it is what keeps his phone quiet on the
                // way out as well as on the way in.
                guard let device = classic[gone] else { continue }
                btTrace("classic disconnected: \(device.name)")
                ConnectionActivityManager.shared.announceBluetooth(
                    name: device.name, percent: nil, connected: false)
            }
        }
        announcedClassic = ids

        let stale = Set(classic.keys).subtracting(ids)
        if !stale.isEmpty {
            for id in stale { classic.removeValue(forKey: id) }
            publish()
        }

        // The free refresh. Every connected device IOBluetooth can answer for is now updated
        // in-process on the bare watch tick, which is what removes `subscribers > 0` from the
        // condition below: an open panel used to spawn `system_profiler` every five seconds
        // for numbers that were already sitting in the sweep that watched membership.
        applyIOReadings(readings)

        // The tool is still the only source for two things: the name Lionel actually set --
        // IOBluetooth reports `AirPods Pro` while a link is up and his own name only while it
        // is down -- and any connected device whose charge IOBluetooth does not carry. So it
        // runs on a membership change, for an announcement, or when someone connected is still
        // unaccounted for; never on the bare tick.
        //
        // The condition is deliberately about devices the tool is *still* the source for, not
        // about devices nothing can answer for. His phone and his watch are connected classic
        // devices that publish no battery to either source, so "unaccounted for" would have
        // been permanently true while either was linked -- spawning on every tick, which is
        // worse than the behaviour this replaces.
        let toolOnly = ids.contains { readings[$0] == nil && classic[$0] != nil }
        if changed || !pendingAnnounceClassic.isEmpty || (subscribers > 0 && toolOnly) {
            readClassicBattery(force: changed || !pendingAnnounceClassic.isEmpty)
        }
    }

    /// What one connected device reports over IOBluetooth.
    private struct Reading: Equatable {
        var left: Int?
        var right: Int?
        var caseCharge: Int?
        var single: Int?

        /// The lower of the two buds, or the single figure. Same rule the tool path uses.
        var percent: Int? {
            if let left, let right { return min(left, right) }
            return left ?? right ?? single
        }
    }

    /// Battery straight off the paired-device sweep, in-process.
    ///
    /// Measured against bluetoothd's own record seconds apart: it logged
    /// `Battery L -61% R -56%` while this read `61` / `58`. The same `pairedDevices()` call
    /// that watches membership carries the charge, so the numbers on the DEVICES page cost
    /// nothing beyond a poll that was already happening.
    ///
    /// > `isMultiBatteryDevice` looks like the shape test and is not: it reads **0** for the
    /// > AirPods Pro while left and right both report. Presence of the two sides is the test.
    ///
    /// Zero is read as "not reporting" rather than as a charge -- the case answers 0 whenever
    /// it is shut or out of range, which is most of the time. A device genuinely at 0% is off,
    /// and so is not connected to be asked.
    private static func ioBattery(_ device: IOBluetoothDevice) -> Reading? {
        func read(_ key: String) -> Int? {
            guard device.responds(to: Selector(key)),
                  let value = device.value(forKey: key) as? Int, value > 0
            else { return nil }
            return min(value, 100)
        }
        let reading = Reading(left: read("batteryPercentLeft"),
                              right: read("batteryPercentRight"),
                              caseCharge: read("batteryPercentCase"),
                              single: read("batteryPercentSingle") ?? read("batteryPercentCombined"))
        return reading.percent == nil ? nil : reading
    }

    /// Fold the in-process readings into the page, keeping the name already established for
    /// the device -- the tool's name outranks IOBluetooth's, and a device first seen here gets
    /// IOBluetooth's only until the spawn on the same membership change corrects it.
    private func applyIOReadings(_ readings: [String: Reading]) {
        guard !readings.isEmpty else { return }
        let appendHistory = Date.now.timeIntervalSince(lastClassicHistory) >= 60
        var touched = false

        for (id, reading) in readings {
            guard let percent = reading.percent else { continue }
            let existing = classic[id]
            var history = existing?.history ?? []
            if appendHistory || history.isEmpty {
                history.append(Double(percent) / 100)
                if history.count > 60 { history.removeFirst(history.count - 60) }
            }
            let device = Device(
                id: id, name: existing?.name ?? classicConnected[id] ?? "Bluetooth device",
                percent: percent, left: reading.left, right: reading.right,
                caseCharge: reading.caseCharge, history: history,
                firstPercent: existing?.firstPercent ?? percent,
                firstSeen: existing?.firstSeen ?? .now)
            if device != existing { touched = true }
            classic[id] = device
        }

        if appendHistory { lastClassicHistory = .now }
        if touched { publish() }
    }

    /// The expensive half: `system_profiler`, through the helper, because the sandbox cannot
    /// spawn it. ~40 ms of CPU, so it is floored and never runs on the bare watch tick.
    private func readClassicBattery(force: Bool = false) {
        guard !readingClassic else { return }
        guard force || Date.now.timeIntervalSince(lastClassicRead) >= Self.classicReadFloor
        else { return }
        readingClassic = true
        lastClassicRead = .now
        Task { @MainActor [weak self] in
            let json = await XPCHelperClient.shared.bluetoothDevices()
            self?.applyClassic(json)
        }
    }

    private func applyClassic(_ json: String?) {
        readingClassic = false
        guard let json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["SPBluetoothDataType"] as? [[String: Any]]
        else {
            btTrace("classic read failed")
            return
        }

        // `device_connected` is a list of single-entry dictionaries keyed by device name --
        // and only connected devices carry a battery, which is exactly the right semantics.
        var found: [String: Device] = [:]
        for block in blocks {
            guard let connected = block["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, raw) in entry {
                    guard let properties = raw as? [String: Any],
                          let address = properties["device_address"] as? String,
                          let percent = Self.charge(properties) else { continue }
                    let id = Self.canonical(address)
                    let existing = classic[id]
                    var history = existing?.history ?? []
                    history.append(Double(percent) / 100)
                    if history.count > 60 { history.removeFirst(history.count - 60) }
                    found[id] = Device(
                        id: id, name: name, percent: percent,
                        left: Self.percent(properties["device_batteryLevelLeft"]),
                        right: Self.percent(properties["device_batteryLevelRight"]),
                        caseCharge: Self.percent(properties["device_batteryLevelCase"]),
                        history: history,
                        firstPercent: existing?.firstPercent ?? percent,
                        firstSeen: existing?.firstSeen ?? .now)
                }
            }
        }
        // Merged, not replaced. The tool no longer runs on every tick, so `classic` may
        // already hold entries this read knows nothing about -- anything IOBluetooth answered
        // for in between. Whatever the tool did find wins, because it carries the name Lionel
        // set; anything it did not is left alone and pruned by the membership poll if it
        // actually goes away.
        for (id, device) in found { classic[id] = device }
        btTrace("classic read -> \(found.count): \(found.values.map(\.name).joined(separator: ", "))")

        // Every pending announcement resolves here -- cleared unconditionally, so nothing can
        // queue forever -- but only a device that actually reports a charge gets said out loud.
        //
        // This is the half that silences his phone and his watch. Both are paired, both come
        // and go as Continuity puts a link up and takes it down, and neither publishes a
        // battery over Bluetooth at all: they are *presence beacons*, and the spec above
        // measured exactly that (`Nearby Info`, no battery field, no GATT services). Device
        // class cannot tell them apart from a mouse -- phone, watch, mouse and one pair of
        // headphones all report `major = 0, Miscellaneous` on this Mac, measured -- so the
        // charge is the only honest discriminator available, and it happens to be the right
        // one: the notch announces what it can show, and a beacon has nothing to show.
        for id in pendingAnnounceClassic {
            // `found` first, then what IOBluetooth already established: the charge gate below
            // is about whether the device reports one *at all*, and since this read stopped
            // being the only source, the tool missing a device no longer means it is a beacon.
            guard let device = found[id] ?? classic[id] else { continue }
            // One device, one activity: a peripheral the Low Energy path already knows about
            // must not announce itself twice under a slightly different name.
            guard !collected.values.contains(where: {
                $0.name.caseInsensitiveCompare(device.name) == .orderedSame
            }) else { continue }
            ConnectionActivityManager.shared.announceBluetooth(
                name: device.name, percent: device.percent, connected: true)
        }
        pendingAnnounceClassic.removeAll()

        publish()
    }

    /// The lower of the two earbuds, or whatever single figure the device reports.
    private static func charge(_ properties: [String: Any]) -> Int? {
        let left = percent(properties["device_batteryLevelLeft"])
        let right = percent(properties["device_batteryLevelRight"])
        if let left, let right { return min(left, right) }
        return left ?? right
            ?? percent(properties["device_batteryLevelMain"])
            ?? percent(properties["device_batteryLevel"])
    }

    /// `system_profiler` reports these as strings with a percent sign: `"82%"`.
    private static func percent(_ raw: Any?) -> Int? {
        guard let text = raw as? String, let value = Int(text.prefix { $0.isNumber })
        else { return nil }
        return min(max(value, 0), 100)
    }

    /// IOBluetooth writes `04-9d-05-88-3b-a2`, `system_profiler` writes `04:9D:05:88:3B:A2`.
    /// The same device, and the only key the two sources have in common.
    private static func canonical(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
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
                classic.removeAll()
                classicConnected.removeAll()

                // And forget that we ever took stock, which is the half that was missing.
                //
                // This is the bug that announced "MX Master 3S disconnected" a moment after
                // Bluetooth was switched back *on*, with nothing connected at all and the
                // mouse not even in the room. `announced` survived the power-off and
                // `adopted` stayed true, so the first poll after power-on diffed an empty
                // connected list against a set still holding the devices from before the
                // toggle -- and dutifully reported every one of them leaving. Worse, it fired
                // on the *rising* edge: the radio coming back is the one moment a user is
                // certain nothing has gone away.
                //
                // Turning the radio off is not a device walking away. Drop the bookkeeping
                // with the readings, and let the first poll after power-on adopt whatever is
                // there in silence, exactly as the first poll of a session does.
                announced.removeAll()
                announcedClassic.removeAll()
                unconfirmedClassic.removeAll()
                pendingAnnounce.removeAll()
                pendingAnnounceClassic.removeAll()
                selfCancelled.removeAll()
                adopted = false
                adoptedClassic = false

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
