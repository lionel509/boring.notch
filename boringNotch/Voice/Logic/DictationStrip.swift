//
//  DictationStrip.swift
//  boringNotch
//
//  One source for the dictation strip's width. The chin (ContentView) and the activity
//  (VoiceDictationLiveActivity) both ask this, so the strip can never outgrow the chin.
//

import Foundation

enum DictationStrip {
    /// Width of the message cell that failures and the model download add.
    static let messageWidth: CGFloat = 150
    /// Longest headline the message cell is sized for.
    static let headlineMax = 28

    /// Width added beside the notch: two square cells (`side` each) plus 20 pt, and one
    /// message cell when the strip says words (the download only).
    static func extraWidth(side: CGFloat, showsMessage: Bool) -> CGFloat {
        2 * max(0, side) + 20 + (showsMessage ? messageWidth : 0)
    }

    /// The failure strip's right-hand cell: the bars' slot plus the 20 pt, so a failure keeps the
    /// listening footprint. The icon cell (`side`) and this cell add up to `extraWidth(showsMessage: false)`.
    static func failureCellWidth(side: CGFloat) -> CGFloat {
        max(0, side) + 20
    }

    /// The part of a message before the first "." or ":", trimmed. The whole message when
    /// it has neither. Capped at `headlineMax` characters, the last one an ellipsis, so runtime
    /// error text cannot overflow the cell.
    static func headline(_ message: String) -> String {
        let head: String
        if let cut = message.firstIndex(where: { $0 == "." || $0 == ":" }) {
            head = String(message[..<cut]).trimmingCharacters(in: .whitespaces)
        } else {
            head = message.trimmingCharacters(in: .whitespaces)
        }
        guard head.count > headlineMax else { return head }
        return String(head.prefix(headlineMax - 1)) + "…"
    }
}
