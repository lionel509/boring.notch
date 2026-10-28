import Foundation

/// Turns the raced XPC reply for a focused-text read into a snapshot or one fixed reason (#47).
enum GhostSnapshotRead: Equatable {
    case snapshot(GhostTextSnapshot, viaFrontmost: Bool, axError: Int?)
    case failed(GhostTextEvent.Reason, axError: Int?)

    /// The only failure tokens the helper may send. Anything else is decodeFailed.
    static let helperFailures: [GhostTextEvent.Reason] = [.untrusted, .noFocusedApp, .encodeFailed]

    /// Insert writes through the system-wide focus (ghostInsert), so a frontmost-app fallback read may name a
    /// different element. Refuse it, and say why (round-1 fix 1). nil means the read may be used for insert.
    static func insertRefusal(_ read: GhostSnapshotRead) -> GhostTextEvent.Reason? {
        if case .snapshot(_, viaFrontmost: true, _) = read { return .fallbackInsert }
        return nil
    }

    /// `raced` is TimeoutRace's result: outer nil = timed out, inner nil = XPC error.
    static func classify(_ raced: String??, frontmostBundleID: String?) -> GhostSnapshotRead {
        guard let reply = raced else { return .failed(.xpcTimeout, axError: nil) }
        guard let json = reply else { return .failed(.xpcError, axError: nil) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return .failed(.decodeFailed, axError: nil)
        }
        let axError = obj["axError"] as? Int
        if let token = obj["failure"] {
            if let name = token as? String, let reason = GhostTextEvent.Reason(rawValue: name),
               helperFailures.contains(reason) {
                return .failed(reason, axError: axError)
            }
            return .failed(.decodeFailed, axError: nil)
        }
        guard let snapshot = GhostTextSnapshot.decode(json) else {
            return .failed(.decodeFailed, axError: nil)
        }
        let viaFrontmost = (obj["focusVia"] as? String) == "frontmost"
        if viaFrontmost, frontmostBundleID == nil || snapshot.bundleID != frontmostBundleID {
            return .failed(.notFrontmost, axError: axError)
        }
        return .snapshot(snapshot, viaFrontmost: viaFrontmost, axError: viaFrontmost ? axError : nil)
    }
}
