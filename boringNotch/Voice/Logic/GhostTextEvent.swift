import Foundation

/// One log line per ghost-text event. Numbers and enum names only: never field or suggestion text.
enum GhostTextEvent: String, CaseIterable {
    case call, shown, accepted, dismissed, dropped

    /// Why a `dropped` line happened. Fixed tokens only, one per guard.
    enum Reason: String, CaseIterable {
        case noSnapshot, decodeFailed, policy, noCaretLocation, noCaretRect, noFieldRect, noRoom, noPrompt
        case noAnchor, anchorMismatch, insertFailed
    }

    static func line(_ event: GhostTextEvent, callsTotal: Int, reason: Reason? = nil,
                     check: GhostTextPolicy.Check? = nil, insertResult: Int? = nil) -> String {
        var out = "ghost event=\(event.rawValue) calls=\(callsTotal)"
        if let reason { out += " reason=\(reason.rawValue)" }
        if let check { out += " check=\(check.rawValue)" }
        if let insertResult { out += " insertResult=\(insertResult)" }
        return out
    }
}
