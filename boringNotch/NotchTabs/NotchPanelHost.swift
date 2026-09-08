//
//  NotchPanelHost.swift
//  boringNotch
//
//  Renders one tab: a rail of panel names over the split-flap deck.
//

import Defaults
import SwiftUI

/// The single place a fork tab is drawn. `ContentView`'s switch names this type once and then
/// never changes again, however many tabs or panels get added later.
struct NotchPanelHost: View {
    let tab: NotchViews

    @ObservedObject private var router = NotchPanelRouter.shared
    @Default(.notchPanelFlipInterval) private var flipInterval

    private var current: Binding<NotchPanel?> {
        Binding(
            get: { router.panel(for: tab) },
            set: { if let panel = $0 { router.select(panel) } })
    }

    var body: some View {
        GeometryReader { proxy in
            FlipDeck(
                pages: tab.panels,
                current: current,
                interval: flipInterval,
                onPageChange: { leaving, arriving in
                    // The battery rule: a panel's manager runs only while that panel is on
                    // screen. Because the deck shows one at a time, eleven panels cost about
                    // what one does.
                    leaving?.deactivate()
                    arriving?.activate()
                }
            ) { panel in
                panelView(for: panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .environment(\.notchPanelHeight, proxy.size.height)
            .environment(\.panelAccent, tab.accent)
        }
        // Inside the host, not on the shared container, so home and shelf stay pixel-identical.
        .safeAreaInset(edge: .top, spacing: 0) {
            if tab.panels.count > 1 { PanelRail(tab: tab) }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func panelView(for panel: NotchPanel) -> some View {
        switch panel {
        case .claudeSessions: ClaudeSessionsPanel()
        case .claudeUsage: ClaudeUsagePanel()
        case .vpn: VPNPanel()
        case .tailnet: TailnetPanel()
        case .resources: ResourcesPanel()
        case .offenders: OffendersPanel()
        case .battery: BatteryPanel()
        case .fleet: FleetPanel()
        case .nas: NASPanel()
        case .downloads: DownloadsPanel()
        case .alerts: AlertsPanel()
        }
    }
}

/// The panel names, in the same typographic voice as the stats strip's own caption. Doubles as
/// the label the icon-only tab bar cannot provide.
struct PanelRail: View {
    let tab: NotchViews
    @ObservedObject private var router = NotchPanelRouter.shared

    var body: some View {
        HStack(spacing: 11) {
            ForEach(tab.panels, id: \.self) { panel in
                let selected = router.panel(for: tab) == panel
                Button {
                    withAnimation(.smooth) { router.select(panel) }
                } label: {
                    Text(panel.title.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(selected
                            ? AnyShapeStyle(tab.accent)
                            : AnyShapeStyle(Color.white.opacity(0.28)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .frame(height: 17)
        .padding(.horizontal, 4)
        .padding(.bottom, 3)
    }
}
