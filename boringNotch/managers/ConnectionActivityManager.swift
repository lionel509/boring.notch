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

    /// The settle timer. Cancelled and restarted by every event, so a burst of them -- which
    /// is what changing network looks like from here -- produces exactly one announcement.
    private var pending: Task<Void, Never>?

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
        // Whether the SSID actually resolves, which is the only question that matters and
        // the one thing an authorisation status does not answer on its own. The *name* is
        // deliberately not written down -- only whether there is one.
        btTrace("wifi auth \(location.authorizationStatus.rawValue), ssid \(interface?.ssid() == nil ? "nil" : "available"), rate \(Int(interface?.transmitRate() ?? 0))")
    }

    /// Every link and SSID event lands here, and none of them announce anything directly.
    ///
    /// Switching networks is not one event, it is several: the radio drops the old access
    /// point, sits unassociated for a moment, then joins the new one. Announcing each event
    /// as it arrived produced "Wi-Fi lost", then the new name, then the link -- three
    /// activities for one thing happening. And reading the radio at the instant of an event
    /// reads it mid-association, when `ssid` is nil and `transmitRate` is still zero.
    ///
    /// So every event just resets a timer. Whatever the radio settles into after the last
    /// one is what gets announced, once.
    fileprivate func wifiChanged() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            ConnectionActivityManager.shared.announceSettled()
        }
    }

    private func announceSettled() {
        let interface = CWWiFiClient.shared().interface()
        let ssid = interface?.ssid()
        let associated = ssid != nil || (interface?.rssiValue() ?? 0) != 0

        defer { wasOnWiFi = associated; lastSSID = ssid ?? lastSSID }
        guard let previously = wasOnWiFi else { return }

        let joined = associated && !previously
        let left = !associated && previously
        let switched = associated && previously && ssid != nil && ssid != lastSSID
        guard joined || left || switched else { return }

        logger.notice("wifi settled: \(associated ? "on" : "off", privacy: .public)")

        guard associated else {
            BoringViewCoordinator.shared.toggleSneakPeek(
                status: true, type: .wifi, duration: 4, value: 0,
                icon: "wifi.slash", detail: lastSSID ?? "no network", detailSecondary: "")
            return
        }
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .wifi, duration: 4, value: 1,
            icon: "wifi",
            detail: Self.networkName(interface),
            detailSecondary: Self.linkDetail(interface))
    }

    /// The network's name, when macOS will give it.
    ///
    /// Falls back to the link rather than nagging: if Location is refused the activity still
    /// says something true instead of disappearing or begging.
    private static func networkName(_ interface: CWInterface?) -> String {
        guard let interface, let ssid = interface.ssid(), !ssid.isEmpty else {
            // Location refused or not yet granted: say the link rather than nothing.
            return linkDetail(interface).isEmpty ? "connected" : linkDetail(interface)
        }
        return ssid
    }

    /// The second beat: how good the link is, once the name has had its moment.
    private static func linkDetail(_ interface: CWInterface?) -> String {
        guard let interface else { return "" }
        var parts: [String] = []
        let rate = interface.transmitRate()
        if rate > 0 { parts.append("\(Int(rate.rounded())) Mbps") }
        let rssi = interface.rssiValue()
        if rssi != 0 { parts.append("\(rssi) dBm") }
        // Both figures if the radio has them by now -- after the settle delay it usually
        // does, and "-61 dBm" alone was a thin thing to have waited for.
        return parts.joined(separator: " · ")
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
