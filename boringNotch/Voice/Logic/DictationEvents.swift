//
//  DictationEvents.swift
//  boringNotch
//

/// Marks every event the dictation rewrite synthesizes, so the app's own taps and monitors can tell
/// "our keystroke" from "the user touched the text". The helper keeps an identical copy at
/// BoringNotchXPCHelper/DictationEvents.swift; DictationEventsTests fails if the two drift.
enum DictationEvents {
    /// ASCII "BNDC".
    static let tag: Int64 = 0x424E4443
}
