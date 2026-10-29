import Foundation

/// The field an accepted ghost suggestion goes into. There is deliberately no way to set the whole value.
protocol GhostTextField {
    var selection: (location: Int, length: Int)? { get }
    var value: String? { get }
    func setSelectedText(_ text: String) -> Bool
    func string(location: Int, length: Int) -> String?
}

/// Insert-time guard for ghost text. Byte-identical copies live in boringNotch/Voice/Logic and BoringNotchXPCHelper.
enum GhostInsertCheck {
    enum Result: Int { case inserted = 0, setFailed = 2, unverified = 3, refused = 5, typed = 7, focusMoved = 10 }

    /// True only when the caret is an empty selection at `expectedLocation` (UTF-16) and only whitespace follows it.
    static func allows(selectionLocation: Int, selectionLength: Int, expectedLocation: Int,
                       fieldLength: Int, textAfterCaret: String) -> Bool {
        selectionLength == 0 && selectionLocation == expectedLocation
            && expectedLocation >= 0 && expectedLocation <= fieldLength
            && textAfterCaret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The typed fallback runs only after a definite set failure, on a successful settability query that says not settable.
    static func mayType(_ r: Result, querySucceeded: Bool, settable: Bool) -> Bool {
        r == .setFailed && querySucceeded && !settable
    }

    /// The caret precondition for an insert: an empty selection at `expectedLocation`, only whitespace after it.
    static func ready(_ text: String, at expectedLocation: Int, in field: GhostTextField) -> Bool {
        guard !text.isEmpty, let sel = field.selection, let value = field.value else { return false }
        let ns = value as NSString
        let after = ns.substring(from: min(max(expectedLocation, 0), ns.length))
        return allows(selectionLocation: sel.location, selectionLength: sel.length, expectedLocation: expectedLocation,
                      fieldLength: ns.length, textAfterCaret: after)
    }

    /// Round 12 (#47): web content (an AXWebArea ancestor) ignores AX writes (Safari live test: 3), so it is typed and
    /// never AX-written. Elsewhere the AX write goes first; typing follows only a definite failure on a not-settable
    /// attribute that left the value byte-identical. `type` runs at most once, returns false when the focus moved,
    /// and never runs after .inserted or .unverified.
    static func accept(_ text: String, at expectedLocation: Int, into field: GhostTextField, inWebArea: Bool,
                       settable: () -> Bool?, type: (String) -> Bool) -> Result {
        if inWebArea {
            guard ready(text, at: expectedLocation, in: field) else { return .refused }
            return type(text) ? .typed : .focusMoved
        }
        let before = field.value
        let result = insert(text, at: expectedLocation, into: field)
        let s = settable()
        guard mayType(result, querySucceeded: s != nil, settable: s ?? true), field.value == before else { return result }
        return type(text) ? .typed : .focusMoved
    }

    static func insert(_ text: String, at expectedLocation: Int, into field: GhostTextField) -> Result {
        guard ready(text, at: expectedLocation, in: field) else { return .refused }
        guard field.setSelectedText(text) else {
            // A failed set may still have written (timeout, write-then-error): never report it as nothing written.
            return field.string(location: expectedLocation, length: (text as NSString).length) == text ? .inserted : .setFailed
        }
        return field.string(location: expectedLocation, length: (text as NSString).length) == text ? .inserted : .unverified
    }
}
