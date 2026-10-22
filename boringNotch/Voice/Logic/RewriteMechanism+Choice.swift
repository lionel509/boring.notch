//
//  RewriteMechanism+Choice.swift
//  boringNotch
//

import Foundation

extension RewriteMechanism {
    /// Bundles where a plain AX value write was verified by the spike (scripts/ax-spike). `com.apple.*`
    /// text fields that are settable are also `.ax` (see `choose`).
    static let axWritable: Set<String> = [
        "com.apple.TextEdit", "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS", "com.apple.dt.Xcode",
    ]

    /// Bundles where the selection is settable but the value write is not trusted: text goes in as key events
    /// after an AX selection (Electron and Chromium editors).
    static let axSelectable: Set<String> = [
        "com.microsoft.VSCode", "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.google.Chrome", "md.obsidian",
    ]

    /// The mechanism for one take, from the focused field the helper reported. Unknown bundles never get `.ax`.
    static func choose(field: FocusedField) -> RewriteMechanism {
        if field.secure { return .none }
        let bundle = field.bundle ?? ""
        if field.textSettable, axWritable.contains(bundle) || bundle.hasPrefix("com.apple.") {
            return .ax
        }
        if axSelectable.contains(bundle) || field.rangeSettable {
            return .axSelectType
        }
        return .keys
    }
}
