//
//  StatsPalette.swift
//  boringNotch
//
//  Severity colours shared by every readout in the notch.
//

import SwiftUI

/// Load severity, deliberately short of a full traffic-light ramp.
///
/// There is no "good" green for a load figure. A readout that turns green to say nothing is
/// wrong is noise — the value is already right there, and colour that is always on stops
/// meaning anything. Normal sits in the user's own accent, and the semantic steps appear only
/// when the number actually warrants a look. Colour is never the sole channel: every cell has
/// a text label and the figure itself.
///
/// Shared with the alert rules and with every tab sub-page, so the whole surface speaks one
/// colour vocabulary rather than inventing a second one per screen.
enum StatsPalette {
    static let serious = Color(red: 0.925, green: 0.514, blue: 0.353)   // #ec835a
    static let critical = Color(red: 0.816, green: 0.231, blue: 0.231)  // #d03b3b
    /// Nothing in the load strip is ever *good*, so this step exists for readouts that report
    /// a success — a reachable host, a passing leak test. 10.4:1 on black, well clear of the
    /// 3:1 the other two were held to.
    static let good = Color(red: 0.361, green: 0.800, blue: 0.510)      // #5ccc82

    /// Both steps clear 3:1 on black and separate by ΔE 11.3 under deuteranopia, checked
    /// against this surface rather than assumed.
    static func severity(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: .effectiveAccent
        case ..<0.90: serious
        default: critical
        }
    }
}
