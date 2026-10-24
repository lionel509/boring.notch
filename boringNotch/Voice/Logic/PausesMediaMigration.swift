//
//  PausesMediaMigration.swift
//  boringNotch
//
//  The one-time clearing of `dictationPausesMedia` (#17 U3 review). The take no longer pauses music, but a
//  `true` stored before this change would still pause it. Launch clears the key once, then never again.
//

import Foundation

enum PausesMediaMigration {
    /// True when launch should clear `dictationPausesMedia`: only the first launch that has not done it yet.
    static func shouldReset(alreadyDone: Bool) -> Bool {
        false
    }
}
