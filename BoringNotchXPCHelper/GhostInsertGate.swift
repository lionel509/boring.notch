import Foundation

/// Insert-time gate for ghost text (#47, review finding 5). Byte-identical copies live in
/// boringNotch/Voice/Logic and BoringNotchXPCHelper, so the app and the helper decide with the same code.
enum GhostInsertGate {
    /// Helper replies added to ghostInsert's codes (0 inserted, 2 set failed, 3 unverified, 4 no focus,
    /// 5 refused, 6 not trusted, 7 typed fallback; -1 is the app's XPC failure).
    enum Refusal: Int, CaseIterable { case staleToken = 8, notFrontmost = 9, focusMoved = 10, secure = 11 }

    /// Insert re-reads the field just before it writes, so the token it sends is milliseconds old.
    static let tokenLifetime: TimeInterval = 2.0

    /// A secure field, or one whose role cannot be read or is empty (fail closed).
    static func isSecure(role: String?, subrole: String?) -> Bool {
        guard let role, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    /// Helper side, inside ghostInsert, before any write. nil means the write may go ahead.
    /// `age` is nil when the token is unknown: never issued, already used, replaced by a newer read, or the helper restarted.
    static func refusal(age: TimeInterval?, pidFrontmost: Bool, focusUnchanged: Bool,
                        role: String?, subrole: String?) -> Refusal? {
        guard let age, age >= 0, age <= tokenLifetime else { return .staleToken }
        guard pidFrontmost else { return .notFrontmost }
        guard focusUnchanged else { return .focusMoved }
        guard !isSecure(role: role, subrole: subrole) else { return .secure }
        return nil
    }

    /// App side: fetch asks it before showing a suggestion and insert asks it before calling ghostInsert,
    /// so the two always agree, for direct and frontmost-fallback reads alike.
    static func appAllows(token: String?, isSecure secure: Bool, role: String, subrole: String) -> Bool {
        guard let token, !token.isEmpty, !secure, !role.isEmpty else { return false }
        return !isSecure(role: role, subrole: subrole)
    }

    /// After an accept swallowed Option+Tab. `result` is ghostInsert's reply, or nil when the app refused before calling it.
    /// True only when nothing can have been written (never after 0, 2, 3, 7 or -1) and the app the key was pressed in is still frontmost.
    static func passThrough(result: Int?, keyApp: String?, frontNow: String?) -> Bool {
        guard let keyApp, !keyApp.isEmpty, keyApp == frontNow else { return false }
        guard let result else { return true }
        return [4, 5, 6].contains(result) || Refusal(rawValue: result) != nil
    }
}

/// One-slot, one-use store for the field the newest read found. Used by the helper; generic so it is testable here.
struct GhostTokenSlot<Value> {
    private var entry: (token: String, value: Value, at: TimeInterval)?

    init() {}

    /// Replaces whatever was stored, so only the newest read's token is ever valid.
    mutating func put(_ value: Value, now: TimeInterval, token: String = UUID().uuidString) -> String {
        entry = (token, value, now)
        return token
    }

    mutating func clear() { entry = nil }

    /// The stored value and its age when `token` is the current one. Always empties the slot.
    mutating func take(_ token: String, now: TimeInterval) -> (value: Value, age: TimeInterval)? {
        defer { entry = nil }
        guard !token.isEmpty, let entry, entry.token == token else { return nil }
        return (entry.value, now - entry.at)
    }
}
