import Foundation

/// One log line per ghost-text event. Numbers and enum names only: never field or suggestion text.
enum GhostTextEvent: String, CaseIterable {
    case call, shown, accepted, dismissed, dropped, fallback, passedThrough

    /// Why a `dropped` line happened. Fixed tokens only, one per guard.
    enum Reason: String, CaseIterable {
        case decodeFailed, policy, noCaretLocation, noCaretRect, noFieldRect, noRoom, noPrompt
        case noAnchor, anchorMismatch, insertFailed
        case untrusted, noFocusedApp, encodeFailed, xpcError, xpcTimeout, notFrontmost, noToken
        case roleNotAllowed, subroleNotAllowed
        /// Round 8 (#31): every outcome after `.call` logs one line.
        case modelError, modelUnavailable, modelEmpty, cleanedAway, overlayNoRoom, overlayNoCaret
        /// Round 9 (#31): a fetch cancelled after `.call`, and an accept whose Option+Tab pass-through failed.
        case cancelled, passThroughFailed
    }

    /// Why a model reply that gave no suggestion was dropped: modelEmpty when blank, cleanedAway otherwise.
    static func noSuggestionReason(_ raw: String) -> Reason {
        raw.allSatisfy { $0.isWhitespace } ? .modelEmpty : .cleanedAway
    }

    /// The `value` for `dropped reason=modelError`: the error's type name, then its GenerationError case name,
    /// or its code when there is no case name. Identifier characters only, so no prompt or reply text gets in.
    static func errorValue(typeName: String, caseName: String?, code: Int) -> String {
        if let caseName { return identifierToken(typeName) + "." + identifierToken(caseName) }
        return identifierToken(typeName) + "#\(code)"
    }

    /// Letters, digits, underscore and dot only, at most 80 characters, `none` when nothing is left.
    private static func identifierToken(_ raw: String) -> String {
        let kept = String(raw.unicodeScalars.filter { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", ".": return true
            default: return false
            }
        }.prefix(80).map(Character.init))
        return kept.isEmpty ? "none" : kept
    }

    /// The allow-list reason for a refused field (#31 round 7).
    static func reason(_ refused: GhostInsertGate.Refused) -> Reason {
        switch refused {
        case .roleNotAllowed: return .roleNotAllowed
        case .subroleNotAllowed: return .subroleNotAllowed
        }
    }

    static func line(_ event: GhostTextEvent, callsTotal: Int, reason: Reason? = nil,
                     check: GhostTextPolicy.Check? = nil, insertResult: Int? = nil,
                     axError: Int? = nil, app: String? = nil, value: String? = nil,
                     snapshotApp: String? = nil, latencyMs: Int? = nil, modelMs: Int? = nil) -> String {
        var out = "ghost event=\(event.rawValue) calls=\(callsTotal)"
        if let reason { out += " reason=\(reason.rawValue)" }
        if let check { out += " check=\(check.rawValue)" }
        if let insertResult { out += " insertResult=\(insertResult)" }
        if let axError { out += " axError=\(axError)" }
        if let app { out += " app=\(appToken(app))" }
        if let value { out += " value=\(escaped(value))" }
        if let snapshotApp { out += " snapshotApp=\(appToken(snapshotApp))" }
        if let latencyMs { out += " latencyMs=\(latencyMs)" }
        if let modelMs { out += " modelMs=\(modelMs)" }
        return out
    }

    /// Whole milliseconds from `start` to `end`, never negative.
    static func latencyMs(from start: TimeInterval, to end: TimeInterval) -> Int { max(0, Int(((end - start) * 1000).rounded())) }

    /// A raw AX value for the log: printable ASCII as-is, except quote and backslash; every other scalar as \u{hex}.
    /// Spaces are escaped too, so padding shows. At most 64 scalars, in double quotes.
    static func escaped(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars.prefix(64) {
            if (0x21...0x7E).contains(scalar.value), scalar != "\"", scalar != "\\" {
                out.unicodeScalars.append(scalar)
            } else {
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            }
        }
        return out + "\""
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
