import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

/// A view model that manages and monitors the battery status of the device
class BatteryStatusViewModel: ObservableObject {

    private var wasCharging: Bool = false
    private var powerSourceChangedCallback: IOPowerSourceCallbackType?
    private var runLoopSource: Unmanaged<CFRunLoopSource>?

    @ObservedObject var coordinator = BoringViewCoordinator.shared

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float = 0.0
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var statusText: String = ""

    private let managerBattery = BatteryActivityManager.shared
    private var managerBatteryId: Int?

    static let shared = BatteryStatusViewModel()

    /// Initializes the view model with a given BoringViewModel instance
    /// - Parameter vm: The BoringViewModel instance
    private init() {
        setupPowerStatus()
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus() {
        let batteryInfo = managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    /// Sets up the monitor to observe battery events
    private func setupMonitor() {
        managerBatteryId = managerBattery.addObserver { [weak self] event in
            guard let self = self else { return }
            self.handleBatteryEvent(event)
        }
    }

    /// Handles battery events and updates the corresponding properties
    /// - Parameter event: The battery event to handle
    private func handleBatteryEvent(_ event: BatteryActivityManager.BatteryEvent) {
        switch event {
        case .powerSourceChanged(let isPluggedIn):
            print("🔌 Power source: \(isPluggedIn ? "Connected" : "Disconnected")")
            withAnimation {
                self.isPluggedIn = isPluggedIn
                self.statusText = self.settledStatusText
                self.notifyImportanChangeStatus()
            }

        case .batteryLevelChanged(let level):
            print("🔋 Battery level: \(Int(level))%")
            withAnimation {
                self.levelBattery = level
            }

        case .lowPowerModeChanged(let isEnabled):
            print("⚡ Low power mode: \(isEnabled ? "Enabled" : "Disabled")")
            self.notifyImportanChangeStatus()
            withAnimation {
                self.isInLowPowerMode = isEnabled
                self.statusText = "Low Power: \(self.isInLowPowerMode ? "On" : "Off")"
            }

        case .isChargingChanged(let isCharging):
            print("🔌 Charging: \(isCharging ? "Yes" : "No")")
            print("maxCapacity: \(self.maxCapacity)")
            print("levelBattery: \(self.levelBattery)")
            // State first, then announce. The notify is debounced, so it reads the phrase
            // after everything has settled -- but ordering it this way means the phrase is
            // right even if the delay is ever shortened.
            withAnimation {
                self.isCharging = isCharging
                self.statusText = self.settledStatusText
            }
            self.notifyImportanChangeStatus()

        case .timeToFullChargeChanged(let time):
            print("🕒 Time to full charge: \(time) minutes")
            withAnimation {
                self.timeToFullCharge = time
            }

        case .maxCapacityChanged(let capacity):
            print("🔋 Max capacity: \(capacity)")
            withAnimation {
                self.maxCapacity = capacity
            }

        case .error(let description):
            print("⚠️ Error: \(description)")
        }
    }

    /// Updates the battery information with the given BatteryInfo instance
    /// - Parameter batteryInfo: The BatteryInfo instance containing the battery data
    private func updateBatteryInfo(_ batteryInfo: BatteryInfo) {
        withAnimation {
            self.levelBattery = batteryInfo.currentCapacity
            self.isPluggedIn = batteryInfo.isPluggedIn
            self.isCharging = batteryInfo.isCharging
            self.isInLowPowerMode = batteryInfo.isInLowPowerMode
            self.timeToFullCharge = batteryInfo.timeToFullCharge
            self.maxCapacity = batteryInfo.maxCapacity
            self.statusText = self.settledStatusText
        }
    }

    /// What the charger is actually doing, in one phrase.
    ///
    /// Read straight from `AppleSmartBattery` rather than from the event-updated flags.
    /// Plugging in is not one event -- the power source changes, then charging starts a
    /// moment later -- so a phrase derived from whichever flag had been set by then said
    /// "Plugged In" and then "Charging" for one action, and could be a whole state behind.
    ///
    /// The important part is `NotChargingReason` / `ChargerInhibitReason`. **Only a non-zero
    /// reason means the charger is being held back.** The first version inferred a hold from
    /// "plugged in but the charging flag is not set yet", which is the absence of evidence
    /// rather than evidence -- and it announced `Paused 29%` on a machine that was charging
    /// perfectly happily at 29%, because the flag simply had not arrived.
    private var settledStatusText: String {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &iterator
        ) == KERN_SUCCESS else { return isPluggedIn ? "Plugged In" : "Unplugged" }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return isPluggedIn ? "Plugged In" : "Unplugged" }
        defer { IOObjectRelease(entry) }

        func value(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        }
        func flag(_ key: String) -> Bool {
            (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) ?? false
        }

        guard flag("ExternalConnected") else { return "Unplugged" }
        if flag("IsCharging") { return "Charging" }
        if flag("FullyCharged") { return "Charged" }

        let level = value("CurrentCapacity")?.intValue ?? Int(levelBattery.rounded())
        let inhibited = (value("NotChargingReason")?.intValue ?? 0) != 0
            || (value("ChargerInhibitReason")?.intValue ?? 0) != 0
        guard inhibited else {
            // Connected, not charging, and nothing is holding it back -- which is what a
            // machine looks like in the moment between the two events. Say the plain true
            // thing rather than inventing a reason.
            return "Plugged In"
        }
        // Above ~75% this is adaptive charging doing its job; below it the charger has been
        // inhibited for some other reason, usually heat.
        return level >= 75 ? "Holding \(level)%" : "Paused \(level)%"
    }

    /// Coalesces a burst of changes into one activity.
    ///
    /// Plug in and three events arrive within a second or so. Each used to raise its own
    /// activity, so the notch said the same thing twice with a jump between them -- which is
    /// what read as an unsmooth animation. One announcement, once the state has stopped
    /// moving.
    private var notifyTask: Task<Void, Never>?

    private func notifyImportanChangeStatus(delay: Double = 0.0) {
        notifyTask?.cancel()
        notifyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(delay, 0.9)))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.statusText = self.settledStatusText
                self.coordinator.toggleExpandingView(status: true, type: .battery)
            }
        }
    }

    deinit {
        print("🔌 Cleaning up battery monitoring...")
        if let managerBatteryId: Int = managerBatteryId {
            managerBattery.removeObserver(byId: managerBatteryId)
        }
    }

}
