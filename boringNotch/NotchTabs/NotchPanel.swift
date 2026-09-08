//
//  NotchPanel.swift
//  boringNotch
//
//  Which sub-pages exist, and which tab each belongs to.
//

import Defaults
import SwiftUI

/// A single sub-page inside a tab.
///
/// Two flat enums on two axes rather than one nested enum: `currentView` is compared with `==`
/// in several places, and associated values would break every one of them. Keeping panels
/// separate also means adding one is `case` + the compiler naming the switches to update —
/// a closure registry would give no such help, and would erase the view identity transitions need.
enum NotchPanel: String, CaseIterable, Hashable {
    case claudeSessions, claudeUsage
    case vpn, tailnet
    case resources, offenders, battery
    case fleet, nas, downloads, alerts

    var tab: NotchViews {
        switch self {
        case .claudeSessions, .claudeUsage: .claude
        case .vpn, .tailnet: .network
        case .resources, .offenders, .battery: .system
        case .fleet, .nas, .downloads, .alerts: .homelab
        }
    }

    /// Shown in the panel rail. A `String` property rather than a literal in a `Text`, because
    /// `SWIFT_EMIT_LOC_STRINGS` extracts every literal into the 600 KB `Localizable.xcstrings`
    /// and turns it into a rebase conflict.
    var title: String {
        switch self {
        case .claudeSessions: "Sessions"
        case .claudeUsage: "Usage"
        case .vpn: "VPN"
        case .tailnet: "Tailnet"
        case .resources: "Resources"
        case .offenders: "Offenders"
        case .battery: "Battery"
        case .fleet: "Fleet"
        case .nas: "NAS"
        case .downloads: "Downloads"
        case .alerts: "Alerts"
        }
    }
}

extension NotchViews {
    /// Home and shelf have none, so they render exactly as they do today with no rail — the
    /// "home stays simple" requirement falls out of the model instead of needing a special case.
    var panels: [NotchPanel] { NotchPanel.allCases.filter { $0.tab == self } }

    var title: String {
        switch self {
        case .home: "Home"
        case .shelf: "Shelf"
        case .claude: "Claude"
        case .network: "Network"
        case .system: "System"
        case .homelab: "Homelab"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.fill"
        case .claude: "sparkle"
        case .network: "network"
        case .system: "gauge.with.dots.needle.33percent"
        case .homelab: "server.rack"
        }
    }

    /// One hue per tab, the way the vault graph gives one hue per vault. Monochrome panels
    /// were correct in the abstract and read as lifeless in practice; a tab's colour also tells
    /// you where you are without reading the rail.
    var accent: Color {
        switch self {
        case .home, .shelf: .effectiveAccent
        case .claude: Color(red: 0.565, green: 0.380, blue: 1.000)   // #9061ff, the vault accent
        case .network: Color(red: 0.290, green: 0.647, blue: 0.937)  // #4aa5ef
        case .system: Color(red: 0.949, green: 0.612, blue: 0.310)   // #f29c4f
        case .homelab: Color(red: 0.361, green: 0.800, blue: 0.510)  // #5ccc82
        }
    }

    /// Same trick `AlertRule.enabled` uses: the toggle is derived from the identity, so a new
    /// tab cannot forget its settings switch.
    var enabledKey: Defaults.Key<Bool> { .init("notchTab.\(rawValue)", default: true) }
}

// MARK: - Sampling lifecycle

/// Where the battery rule is actually enforced.
///
/// A panel claims its manager when it comes on screen and releases it when it flips away, so
/// nothing polls on behalf of a panel nobody is looking at — and a closed notch polls nothing
/// at all. Managers are reference counted, so overlapping claims are safe.
extension NotchPanel {
    @MainActor
    func activate() {
        switch self {
        case .resources, .offenders:
            SystemStatsManager.shared.start()
        case .battery:
            SystemStatsManager.shared.start()
            BluetoothBatteryManager.shared.start()
        case .claudeUsage:
            RouterUsageManager.shared.refresh()
        case .vpn:
            SystemStatsManager.shared.start()
            TailscaleManager.shared.start()
        case .tailnet:
            TailscaleManager.shared.start()
        case .claudeSessions, .fleet, .nas, .downloads, .alerts:
            break
        }
    }

    @MainActor
    func deactivate() {
        switch self {
        case .resources, .offenders:
            SystemStatsManager.shared.stop()
        case .vpn:
            SystemStatsManager.shared.stop()
            TailscaleManager.shared.stop()
        case .tailnet:
            TailscaleManager.shared.stop()
        case .battery:
            SystemStatsManager.shared.stop()
            BluetoothBatteryManager.shared.stop()
        case .claudeSessions, .claudeUsage, .fleet, .nas, .downloads, .alerts:
            break
        }
    }
}
