//
//  sizeMatters.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
/// Height of one stats row — a small uppercase label over the figure, because a row where
/// label and value carry the same weight reads as chrome rather than as something to read.
let statsStripRowHeight: CGFloat = 24

/// The strip is a single row that flips between pages — API usage, then system load — the
/// way a split-flap departure board cycles. Stacking a line per group cost twice the notch
/// height to show numbers that are only glanced at, one group at a time.
var statsStripHeight: CGFloat {
    guard Defaults[.showStatsStrip],
          Defaults[.statsStripShowUsage] || Defaults[.statsStripShowSystem]
    else { return 0 }
    return statsStripRowHeight
}

private let baseOpenNotchSize: CGSize = .init(width: 640, height: 190)

/// The expanded notch.
///
/// 190 pt is upstream's number and stays exactly that with the stats strip off, so the
/// default build is unchanged. With the strip on the notch grows by the strip's height
/// rather than taking that space out of the player.
///
/// The first cut of the strip did stack it inside 190 pt, on the theory that the header
/// (~32) plus `NotchHomeView` (~120) left ~26 pt spare. That arithmetic came off the
/// layout constants, not off the rendered view, and it was wrong — the expanded notch has
/// no slack. Stacking a row inside it pushed the tab buttons up into the physical bezel
/// and collapsed the music column until the transport buttons overlapped the progress bar.
var openNotchSize: CGSize {
    .init(
        width: baseOpenNotchSize.width,
        height: baseOpenNotchSize.height + statsStripHeight
    )
}

/// Always sized for the strip, so toggling the setting never needs a relaunch to avoid
/// clipping. The window is transparent outside the notch shape, so the extra height costs
/// nothing visually — it is the same trick `shadowPadding` already relies on.
let windowSize: CGSize = .init(
    width: baseOpenNotchSize.width,
    height: baseOpenNotchSize.height + statsStripRowHeight + shadowPadding)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
