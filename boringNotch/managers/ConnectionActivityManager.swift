//
//  ConnectionActivityManager.swift
//  boringNotch
//
//  "Wi-Fi connected" on the left of the notch, which network on the right.
//

import CoreLocation
import CoreWLAN
import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "ConnectionActivity")

@MainActor
final class ConnectionActivityManager: NSObject {
    static let shared = ConnectionActivityManager()

    private let location = CLLocationManager()
    private var started = false

    /// Last network seen, so a *change* of network announces itself too -- not just a join
    /// from nothing. Hopping between two access points never crosses an up/down edge.
    private var lastSSID: String?
    private var wasOnWiFi: Bool?

    private override init() { super.init() }

    func start() {
        guard !started else { return }
        started = true

        // The SSID costs a Location grant and nothing else does. Measured: with authorisation
        // `notDetermined`, `ssid()` and `bssid()` return nil while link rate, signal and
        // security all come back fine. Apple gates the *name* because a list of networks is a
        // location history. Asked for once, here, because a Wi-Fi activity that cannot say
        // which Wi-Fi is not worth showing.
        location.delegate = self
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }

        // CoreWLAN's own events, not NWPathMonitor.
        //
        // The path monitor reports how traffic is *routed*, and with a VPN up the default
        // path stops being `.wifi` even though the Mac is still perfectly well associated to
        // an access point. That is why a disconnect was announced and the rejoin never was:
        // NordVPN, not Wi-Fi, was what the monitor was watching. `CWWiFiClient` reports the
        // radio link itself, which is the thing actually being asked about.
        CWWiFiClient.shared().delegate = self
        try? CWWiFiClient.shared().startMonitoringEvent(with: .linkDidChange)
        try? CWWiFiClient.shared().startMonitoringEvent(with: .ssidDidChange)

        let interface = CWWiFiClient.shared().interface()
        wasOnWiFi = interface?.ssid() != nil || (interface?.rssiValue() ?? 0) != 0
        lastSSID = interface?.ssid()
        logger.notice("watching wifi, authorised \(self.location.authorizationStatus.rawValue, privacy: .public)")
    }

    fileprivate func wifiChanged() {
        let interface = CWWiFiClient.shared().interface()
        let ssid = interface?.ssid()
        let associated = ssid != nil || (interface?.rssiValue() ?? 0) != 0

        defer { wasOnWiFi = associated; lastSSID = ssid }
        guard wasOnWiFi != nil else { return }

        // Something worth saying: joined, left, or moved to a different network.
        let joined = associated && wasOnWiFi != true
        let left = !associated && wasOnWiFi == true
        let switched = associated && wasOnWiFi == true && ssid != lastSSID && ssid != nil
        guard joined || left || switched else { return }

        logger.notice("wifi \(associated ? "up" : "down", privacy: .public)")
        // The left already says what happened. Repeating "disconnected" on the right spent
        // the whole slot saying it twice and left no room for the network's name -- which is
        // the only thing the right side is there for.
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .wifi, duration: 4, value: associated ? 1 : 0,
            icon: associated ? "wifi" : "wifi.slash",
            detail: associated ? Self.networkName(interface) : (lastSSID ?? "no network"),
            detailSecondary: associated ? Self.linkDetail(interface) : "")
    }

    /// The network's name, when macOS will give it.
    ///
    /// Falls back to the link rather than nagging: if Location is refused the activity still
    /// says something true instead of disappearing or begging.
    private static func networkName(_ interface: CWInterface?) -> String {
        guard let interface else { return "connected" }
        if let ssid = interface.ssid(), !ssid.isEmpty { return ssid }
        return linkDetail(interface).isEmpty ? "connected" : linkDetail(interface)
    }

    /// The second beat: how good the link is, once the name has had its moment.
    private static func linkDetail(_ interface: CWInterface?) -> String {
        guard let interface else { return "" }
        var parts: [String] = []
        let rate = interface.transmitRate()
        if rate > 0 { parts.append("\(Int(rate.rounded())) Mbps") }
        let rssi = interface.rssiValue()
        if rssi != 0 { parts.append("\(rssi) dBm") }
        // Nothing to slide to if the name *was* the link figures.
        return parts.count > 1 ? parts.joined(separator: " · ") : ""
    }

    /// Announced by `BluetoothBatteryManager` when a device appears or goes away.
    ///
    /// Honest limitation: the *battery* is only read while the notch is open, so a device
    /// connecting when it has never been read announces its name without a charge.
    func announceBluetooth(name: String, percent: Int?, connected: Bool) {
        logger.notice("bluetooth \(connected ? "connected" : "disconnected", privacy: .public)")
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .bluetooth, duration: 4, value: connected ? 1 : 0,
            icon: connected ? "dot.radiowaves.right" : "xmark.circle",
            detail: name,
            detailSecondary: connected ? (percent.map { "\($0)% charged" } ?? "") : "")
    }
}

extension ConnectionActivityManager: CWEventDelegate {
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in ConnectionActivityManager.shared.wifiChanged() }
    }
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in ConnectionActivityManager.shared.wifiChanged() }
    }
}

extension ConnectionActivityManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        logger.notice("location authorisation \(manager.authorizationStatus.rawValue, privacy: .public)")
    }
}
