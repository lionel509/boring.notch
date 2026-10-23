//
//  FocusedField.swift
//  boringNotch
//

import Foundation

/// What the helper reports about the focused text element (its JSON from `beginTracking`).
/// The keys match the helper's JSON exactly.
struct FocusedField: Codable, Equatable {
    var pid: Int
    var bundle: String?
    var role: String
    var secure: Bool
    /// UTF-16 caret offset; -1 when unknown.
    var caret: Int
    var rangeSettable: Bool
    var textSettable: Bool
}
