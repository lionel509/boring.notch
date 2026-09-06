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
    /// Plugging in is not one event: the power source changes, and then charging starts a
    /// moment later. Deriving the phrase from the *current* state rather than from whichever
    /// event just arrived is what stops it announcing "Plugged In" and then "Charging" for
    /// one action.
    ///
    /// The interesting case is the third one. With adaptive charging on, macOS deliberately
    /// stops around 80% and holds there — the charger is connected, the battery is not full,
    /// and nothing is charging. Without a word for that state it reads as a fault, which is
    /// exactly what it looked like.
    private var settledStatusText: String {
        guard isPluggedIn else { return "Unplugged" }
        if isCharging { return "Charging" }
        let level = Int(levelBattery.rounded())
        if level >= 95 { return "Charged" }
        // Held rather than broken. Above ~75% this is adaptive charging doing its job;
        // below it the charger has been inhibited for some other reason, usually heat.
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
