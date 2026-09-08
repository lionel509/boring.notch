//
//  VPNPanel.swift
//  boringNotch
//

import SwiftUI

/// Both VPNs on one page, with the link underneath them.
///
/// The point of the panel is the question the menu bar could never answer: not "is a VPN on"
/// but "which one is actually carrying my traffic, and how much". Tailscale and NordVPN evict
/// each other on macOS — only one NetworkExtension VPN runs at a time — so seeing both states
/// side by side is the whole diagnosis.
struct VPNPanel: View {
    @ObservedObject private var stats = SystemStatsManager.shared
    @ObservedObject private var tailscale = TailscaleManager.shared

    private static let widestRate = "999 MB/s"

    var body: some View {
        Group {
            // The link half is always knowable from local counters, but the Tailscale half
            // needs a round trip through the helper. Showing columns of dashes while that is
            // in flight reads as broken, so the first probe gets its own state.
            if !tailscale.hasProbed && tailscale.statusMessage.isEmpty {
                PanelState(kind: .probing, message: Self.probing)
            } else {
                columns
            }
        }
        .padding(.horizontal, 10)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 20) {
            tailscaleColumn
            nordColumn
            linkColumn
            Spacer(minLength: 0)
        }
    }

    // MARK: Columns

    private var tailscaleColumn: some View {
        PanelColumn(title: Self.tailscaleTitle, width: 168) {
            PanelRow(label: Self.stateLabel,
                     value: tailscale.isRunning ? Self.onValue : Self.offValue,
                     status: tailscale.isRunning ? .up : .down)
            PanelRow(label: Self.addressLabel, value: selfAddress)
            PanelRow(label: Self.downLabel, value: rate(for: .tailscale)?.downText ?? Self.idle)
            PanelRow(label: Self.upLabel, value: rate(for: .tailscale)?.upText ?? Self.idle)
        }
    }

    private var nordColumn: some View {
        PanelColumn(title: Self.nordTitle, width: 168) {
            PanelRow(label: Self.stateLabel,
                     value: nordInterface != nil ? Self.onValue : Self.offValue,
                     status: nordInterface != nil ? .up : .down)
            PanelRow(label: Self.downLabel, value: rate(for: .nord)?.downText ?? Self.idle)
            PanelRow(label: Self.upLabel, value: rate(for: .nord)?.upText ?? Self.idle)
            // NordVPN ships no CLI and no status API on macOS. Connecting works through its
            // URL scheme; disconnecting does not exist. A button that silently does nothing
            // is worse than no button, so the limitation is stated rather than hidden.
            PanelRow(label: Self.controlLabel, value: Self.nordControlNote)
        }
    }

    private var linkColumn: some View {
        PanelColumn(title: Self.linkTitle, width: 168) {
            PanelRow(label: Self.viaLabel, value: viaText)
            PanelRow(label: Self.signalLabel, value: signalText)
            PanelRow(label: Self.rateLabel, value: Units.bitRate(megabitsPerSecond: stats.wifiRate))
            PanelRow(label: Self.ipLabel, value: stats.localIP ?? Self.unknown)
        }
    }

    // MARK: Derivation

    private enum Tunnel { case tailscale, nord }

    /// Interfaces are named by the address block they allocate from, never by their `utun`
    /// number — the kernel renumbers those on every boot.
    private func interface(for tunnel: Tunnel) -> String? {
        let wanted = tunnel == .tailscale ? "TAILSCALE" : "NORDVPN"
        return stats.tunnelAddresses.first {
            SystemStatsManager.vpnName(forTunnelAddress: $0.value) == wanted
        }?.key
    }

    private var nordInterface: String? { interface(for: .nord) }

    private func rate(for tunnel: Tunnel) -> (downText: String, upText: String)? {
        guard let name = interface(for: tunnel), let rate = stats.interfaceRates[name] else { return nil }
        return (Units.byteRate(rate.down), Units.byteRate(rate.up))
    }

    private var selfAddress: String {
        tailscale.nodes.first(where: { $0.isSelf })?.address ?? Self.unknown
    }

    /// Shared with the home strip, so the two surfaces can never word this differently.
    private var viaText: String { stats.egressDisplay }

    private var signalText: String {
        stats.wifiRSSI == 0 ? Self.unknown : "\(stats.wifiRSSI) dBm"
    }

    // MARK: Strings
    // Held as properties rather than inline literals: SWIFT_EMIT_LOC_STRINGS extracts every
    // literal in a Text into Localizable.xcstrings, which is a 600 KB rebase conflict.

    private static let tailscaleTitle = "TAILSCALE"
    private static let nordTitle = "NORDVPN"
    private static let linkTitle = "LINK"
    private static let stateLabel = "State"
    private static let addressLabel = "Address"
    private static let downLabel = "Down"
    private static let upLabel = "Up"
    private static let controlLabel = "Control"
    private static let viaLabel = "Via"
    private static let signalLabel = "Signal"
    private static let rateLabel = "Rate"
    private static let ipLabel = "IP"
    private static let onValue = "On"
    private static let offValue = "Off"
    private static let idle = "—"
    private static let unknown = "—"
    private static let nordControlNote = "app only"
    private static let probing = "Reading VPN state"
}
