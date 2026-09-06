//
//  ConnectionActivityManager.swift
//  boringNotch
//
//  "Wi-Fi connected" on the left of the notch, which network on the right.
//

import CoreWLAN
import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "ConnectionActivity")

/// Announces network and Bluetooth connections as a closed-notch activity.
///
/// Wi-Fi is watched with `NWPathMonitor`, which is free, always on, and needs no permission
/// of any kind. That last part is the whole reason the right-hand side says what it says.
@MainActor
final class ConnectionActivityManager {
    static let shared = ConnectionActivityManager()

    private let monitor = NWPathMonitor()
    private var started = false

    /// `nil` until the first path arrives, so launching while already on Wi-Fi does not
    /// announce a connection that happened before the app existed.
    private var wasOnWiFi: Bool?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            Task { @MainActor [weak self] in self?.handle(path) }
        }
        monitor.start(queue: DispatchQueue(label: "theboringteam.boringnotch.path"))
    }

    private func handle(_ path: NWPath) {
        let onWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
        defer { wasOnWiFi = onWiFi }
        guard let previously = wasOnWiFi else { return }
        guard onWiFi != previously else { return }

        logger.notice("wifi \(onWiFi ? "up" : "down", privacy: .public)")
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .wifi, duration: 2.5,
            icon: onWiFi ? "wifi" : "wifi.slash",
            detail: onWiFi ? Self.wifiDetail() : "disconnected")
    }

    /// What the right-hand side can say without asking for anything.
    ///
    /// Deliberately **not** the network's name. Since macOS 14 `ssid()` and `bssid()` return
    /// `nil` unless the app holds a granted Location Services authorisation — measured on this
    /// machine, where `ipconfig` reports the SSID as `<redacted>` while link rate and signal
    /// come back fine. A notch app asking for your location to name a Wi-Fi network is a bad
    /// trade, so it reports the link instead, which needs no permission and arguably says
    /// more. If the name is ever wanted, that is an opt-in with its own explanation.
    private static func wifiDetail() -> String {
        guard let interface = CWWiFiClient.shared().interface() else { return "connected" }
        var parts: [String] = []
        let rate = interface.transmitRate()
        if rate > 0 { parts.append("\(Int(rate.rounded())) Mbps") }
        let rssi = interface.rssiValue()
        if rssi != 0 { parts.append("\(rssi) dBm") }
        return parts.isEmpty ? "connected" : parts.joined(separator: " · ")
    }

    /// Announced by `BluetoothBatteryManager` when a device appears or goes away.
    ///
    /// Honest limitation, written down rather than hidden: that manager only runs while the
    /// notch is open, because a battery page has no business holding the radio awake. So a
    /// device connecting while the notch is closed is announced the next time the notch is
    /// opened, not at the moment it connects. Announcing at the true moment needs an
    /// always-on central, which means asking for Bluetooth permission at launch for a page
    /// the user may never open.
    func announceBluetooth(name: String, percent: Int?, connected: Bool) {
        let detail: String
        if connected {
            detail = percent.map { "\(name) · \($0)%" } ?? name
        } else {
            detail = "\(name) · disconnected"
        }
        logger.notice("bluetooth device \(connected ? "connected" : "disconnected", privacy: .public)")
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .bluetooth, duration: 2.5,
            icon: connected ? "dot.radiowaves.right" : "xmark.circle", detail: detail)
    }
}
