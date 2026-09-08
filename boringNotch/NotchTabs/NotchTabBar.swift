//
//  NotchTabBar.swift
//  boringNotch
//
//  The tab pill. Mirrors upstream's TabSelectionView rather than editing it.
//

import Defaults
import SwiftUI

/// Upstream's `TabSelectionView` and `TabButton` are byte-identical to their origin, and this
/// fork has to keep rebasing. So they are left untouched and this replaces them at the call
/// site — upstream tab-bar changes then apply forever without a conflict.
///
/// Also drops `matchedGeometryEffect` entirely. `.hidden()` does not remove a view from the
/// geometry registry, so upstream already registers two sources for `id: "capsule"` at two
/// tabs; six would make the warning certain. One capsule offset by index needs no ids at all
/// and scales to any number of tabs.
struct NotchTabBar: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @StateObject private var tvm = ShelfStateViewModel.shared

    /// Equal widths are what let a single capsule be positioned by index. 6 x 29 = 174pt
    /// against the ~196pt the header leaves beside the physical notch.
    private static let buttonWidth: CGFloat = 29
    private static let height: CGFloat = 26

    var body: some View {
        let tabs = visibleTabs
        // One destination is not a tab bar.
        if tabs.count > 1 {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    button(for: tab, in: tabs)
                }
            }
            .background(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .secondarySystemFill))
                    .frame(width: Self.buttonWidth, height: Self.height)
                    .offset(x: Self.buttonWidth * CGFloat(selectedIndex(in: tabs)))
            }
            .animation(.smooth, value: coordinator.currentView)
            .clipShape(Capsule())
            .task { correctIfHidden(tabs) }
        }
    }

    private func button(for tab: NotchViews, in tabs: [NotchViews]) -> some View {
        let selected = coordinator.currentView == tab
        return Button {
            withAnimation(.smooth) {
                // Clicking the tab you are already on cycles its panels, which is how you
                // reach a panel without a gesture that would fight the shelf's scroll view.
                if selected { NotchPanelRouter.shared.advance(in: tab) }
                else { coordinator.currentView = tab }
            }
        } label: {
            Image(systemName: tab.icon)
                .frame(width: Self.buttonWidth, height: Self.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .white : .gray)
        // Six icon-only tabs are not self-describing. The tooltip and the panel rail carry
        // the naming that upstream's TabButton accepted and then never used.
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The shelf gate moves in here, where it belongs, so the other tabs no longer disappear
    /// when the shelf feature is switched off. Upstream's rule is preserved exactly for shelf.
    private var visibleTabs: [NotchViews] {
        NotchViews.allCases.filter { tab in
            switch tab {
            case .home: true
            case .shelf: Defaults[.boringShelf] && (!tvm.isEmpty || coordinator.alwaysShowTabs)
            default: Defaults[tab.enabledKey]
            }
        }
    }

    private func selectedIndex(in tabs: [NotchViews]) -> Int {
        tabs.firstIndex(of: coordinator.currentView) ?? 0
    }

    /// A tab can be switched off in Settings while it is the current view. The header only
    /// mounts when the notch opens, so correcting here catches it before it is ever seen.
    private func correctIfHidden(_ tabs: [NotchViews]) {
        if !tabs.contains(coordinator.currentView) { coordinator.currentView = .home }
    }
}
