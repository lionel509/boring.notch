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
    /// message cell when the strip says words.
    static func extraWidth(side: CGFloat, showsMessage: Bool) -> CGFloat {
        2 * max(0, side) + 20 + (showsMessage ? messageWidth : 0)
    }

    /// The part of a message before the first "." or ":", trimmed. The whole message when
    /// it has neither.
    static func headline(_ message: String) -> String {
        guard let cut = message.firstIndex(where: { $0 == "." || $0 == ":" }) else {
            return message.trimmingCharacters(in: .whitespaces)
        }
        return String(message[..<cut]).trimmingCharacters(in: .whitespaces)
    }
}
