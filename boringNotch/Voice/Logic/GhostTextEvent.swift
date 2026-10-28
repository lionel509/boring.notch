import Foundation

/// One log line per ghost-text event. Numbers and enum names only: never field or suggestion text.
enum GhostTextEvent: String, CaseIterable {
    case call, shown, accepted, dismissed, dropped, fallback

    /// Why a `dropped` line happened. Fixed tokens only, one per guard.
    enum Reason: String, CaseIterable {
        case decodeFailed, policy, noCaretLocation, noCaretRect, noFieldRect, noRoom, noPrompt
        case noAnchor, anchorMismatch, insertFailed
        case untrusted, noFocusedApp, encodeFailed, xpcError, xpcTimeout, notFrontmost, fallbackInsert
    }

    static func line(_ event: GhostTextEvent, callsTotal: Int, reason: Reason? = nil,
                     check: GhostTextPolicy.Check? = nil, insertResult: Int? = nil,
                     axError: Int? = nil, app: String? = nil) -> String {
        var out = "ghost event=\(event.rawValue) calls=\(callsTotal)"
        if let reason { out += " reason=\(reason.rawValue)" }
        if let check { out += " check=\(check.rawValue)" }
        if let insertResult { out += " insertResult=\(insertResult)" }
        if let axError { out += " axError=\(axError)" }
        if let app { out += " app=\(appToken(app))" }
        return out
    }

    /// The app ID as one log token: `[A-Za-z0-9.-]` only, at most 155 characters, `none` when nothing is left.
    static func appToken(_ raw: String) -> String {
        let kept = String(raw.unicodeScalars.filter { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "-": return true
            default: return false
            }
        }.prefix(155).map(Character.init))
        return kept.isEmpty ? "none" : kept
    }
}
