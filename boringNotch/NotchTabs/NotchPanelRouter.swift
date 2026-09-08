//
//  NotchPanelRouter.swift
//  boringNotch
//
//  Which panel each tab is showing.
//

import Defaults
import SwiftUI

/// Owns panel selection, separately from `BoringViewCoordinator`.
///
/// The coordinator is an upstream file already carrying fork changes; keeping panel state out
/// of it means this feature adds nothing to a file that has to survive rebases.
@MainActor
final class NotchPanelRouter: ObservableObject {
    static let shared = NotchPanelRouter()

    /// Tab raw value -> panel raw value. Persisted, so coming back to a tab lands where you
    /// left it rather than resetting to the first panel every time the notch closes.
    @Published private(set) var selection: [String: String]

    private init() {
        selection = Defaults[.notchPanelSelection]
    }

    func panel(for tab: NotchViews) -> NotchPanel? {
        let panels = tab.panels
        guard !panels.isEmpty else { return nil }
        if let raw = selection[tab.rawValue],
           let stored = NotchPanel(rawValue: raw),
           panels.contains(stored) {
            return stored
        }
        return panels.first
    }

    func select(_ panel: NotchPanel) {
        selection[panel.tab.rawValue] = panel.rawValue
        Defaults[.notchPanelSelection] = selection
    }

    /// Clicking the already-active tab cycles its panels. Gives keyboard-free navigation
    /// without a horizontal gesture, which would fight the shelf's own scroll view.
    func advance(in tab: NotchViews) {
        let panels = tab.panels
        guard panels.count > 1, let current = panel(for: tab),
              let index = panels.firstIndex(of: current) else { return }
        select(panels[(index + 1) % panels.count])
    }
}
