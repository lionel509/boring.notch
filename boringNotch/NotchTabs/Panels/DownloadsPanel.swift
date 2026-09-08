//
//  DownloadsPanel.swift
//  boringNotch
//
//  What qBittorrent is pulling down right now.
//

import SwiftUI

private enum Caption {
    static let unset = "Set the qBittorrent WebUI URL in Settings"
    static let credentials = "qBittorrent needs a WebUI username and password"
    static let idle = "Nothing downloading"
    static let probing = "Asking qBittorrent…"
    static let stalled = "stalled"
}

/// Five rows of name, progress and speed. Torrent names are long and the interesting half is
/// usually the end — the release tag, the resolution — so they scroll rather than truncate.
struct DownloadsPanel: View {
    @ObservedObject private var client = QBittorrentManager.shared

    var body: some View {
        Group {
            switch client.state {
            case .unset:
                PanelState(kind: .empty, message: Caption.unset)
            case .probing:
                PanelState(kind: .probing, message: Caption.probing)
            case .needsCredentials:
                PanelState(
                    kind: .empty,
                    message: client.statusMessage.isEmpty
                        ? Caption.credentials : client.statusMessage)
            case .failed(let reason):
                PanelState(kind: .failed, message: reason)
            case .ok:
                if client.torrents.isEmpty {
                    PanelState(kind: .empty, message: Caption.idle)
                } else {
                    content
                }
            }
        }
        .onAppear { client.start() }
        .onDisappear { client.stop() }
    }

    private var content: some View {
        PanelColumn(title: heading, width: 574) {
            ForEach(client.torrents) { torrent in
                row(torrent)
            }
        }
    }

    /// The column caption doubles as the summary line, which buys back a whole row of height
    /// for an extra torrent.
    private var heading: String {
        let count = client.torrents.count
        return "DOWNLOADING · \(count) · \(speed(client.totalDownBytesPerSec))"
    }

    private func row(_ torrent: QBittorrentManager.Torrent) -> some View {
        HStack(spacing: 8) {
            PanelMarqueeLine(text: torrent.name, width: 288)
            MeterBar(fraction: torrent.progress, tint: .effectiveAccent, width: 96)
            Text(HomelabManager.percent(torrent.progress))
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 36, alignment: .trailing)
            Text(speed(torrent.downloadBytesPerSec))
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundStyle(
                    torrent.downloadBytesPerSec > 0 ? .white.opacity(0.62) : StatsPalette.serious)
                .frame(width: 78, alignment: .trailing)
        }
        .frame(height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(torrent.name): \(HomelabManager.percent(torrent.progress)), "
                + speed(torrent.downloadBytesPerSec))
    }

    /// A torrent at zero is not moving, and saying so is more use than a row of 0 B/s.
    private func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return Caption.stalled }
        return HomelabManager.bytes(bytesPerSecond) + "/s"
    }
}
