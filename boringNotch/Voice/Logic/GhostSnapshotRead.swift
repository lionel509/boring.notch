import Foundation

/// Turns the raced XPC reply for a focused-text read into a snapshot or one fixed reason (#47).
enum GhostSnapshotRead: Equatable {
    case snapshot(GhostTextSnapshot, viaFrontmost: Bool, axError: Int?)
    case failed(GhostTextEvent.Reason, axError: Int?, snapshotApp: String? = nil)

    /// The only failure tokens the helper may send. Anything else is decodeFailed.
    static let helperFailures: [GhostTextEvent.Reason] = [.untrusted, .noFocusedApp, .encodeFailed]

    /// An AXError code is an integer. JSONSerialization also bridges a float such as -25212.0, which the helper never sends (round-1 fix 7),
    /// and a JSON boolean, which bridges to an NSNumber too (round-3 finding 4).
    private static func integralAXError(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard type != "f", type != "d" else { return nil }
        return number.intValue
    }

    /// `raced` is TimeoutRace's result: outer nil = timed out, inner nil = XPC error.
    static func classify(_ raced: String??, frontmostBundleID: String?) -> GhostSnapshotRead {
        guard let reply = raced else { return .failed(.xpcTimeout, axError: nil) }
        guard let json = reply else { return .failed(.xpcError, axError: nil) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return .failed(.decodeFailed, axError: nil)
        }
        let axError = integralAXError(obj["axError"])
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
            return .failed(.notFrontmost, axError: axError, snapshotApp: snapshot.bundleID)
        }
        return .snapshot(snapshot, viaFrontmost: viaFrontmost, axError: viaFrontmost ? axError : nil)
    }
}
