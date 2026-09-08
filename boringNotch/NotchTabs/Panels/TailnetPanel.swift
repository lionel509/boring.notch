//
//  TailnetPanel.swift
//  boringNotch
//

import SwiftUI

/// The tailnet, online nodes first.
///
/// Capped deliberately. A list is the wrong shape for 150 pt, and a thirty-node tailnet
/// rendered honestly is unreadable — so the online ones are shown and the rest are counted.
struct TailnetPanel: View {
    @ObservedObject private var tailscale = TailscaleManager.shared

    private static let columns = 3
    private static let rowsPerColumn = 4

    var body: some View {
        Group {
            if !tailscale.statusMessage.isEmpty {
                PanelState(kind: .failed, message: tailscale.statusMessage)
            } else if !tailscale.hasProbed {
                PanelState(kind: .probing, message: Self.probing)
            } else if tailscale.nodes.isEmpty {
                PanelState(kind: .empty, message: Self.empty)
            } else {
                grid
            }
        }
        .padding(.horizontal, 10)
    }

    private var grid: some View {
        let shown = Array(online.prefix(Self.columns * Self.rowsPerColumn))
        let chunks = stride(from: 0, to: shown.count, by: Self.rowsPerColumn).map {
            Array(shown[$0..<min($0 + Self.rowsPerColumn, shown.count)])
        }
        return HStack(alignment: .top, spacing: 20) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                PanelColumn(title: index == 0 ? Self.title : " ", width: 168) {
                    ForEach(chunk) { node in
                        PanelRow(label: node.name, value: node.address, status: .up)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomTrailing) {
            if offlineCount > 0 {
                Text(Self.offlineText(offlineCount))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var online: [TailscaleManager.Node] { tailscale.nodes.filter(\.online) }
    private var offlineCount: Int { tailscale.nodes.count - online.count }

    private static let title = "NODES"
    private static let probing = "Reading tailnet"
    private static let empty = "No nodes — is Tailscale logged in?"
    private static func offlineText(_ count: Int) -> String { "+\(count) offline" }
}
