//
//  RewriteGate.swift
//  boringNotch
//

import Foundation

/// Whether a pasted take is rewritten. Every take that is not rewritten gets a reason (never `.none`).
/// Audio goes to the cloud and text is retyped only through `.run`.
enum RewriteGate {
    enum Decision: Equatable {
        case run(RewriteMechanism)
        case skip(CleanupSkip)
    }

    static func decide(field: FocusedField?, cloudOn: Bool, hasKey: Bool, cleanupOn: Bool, keyAbortLive: Bool) -> Decision {
        guard let field else { return .skip(.noField) }
        let chosen = RewriteMechanism.choose(field: field)
        if field.secure || chosen == .none { return .skip(.secureField) }
        guard (cloudOn && hasKey) || cleanupOn else { return .skip(.cleanupOff) }
        guard RewriteMechanism.effective(chosen, caretReadable: field.caret >= 0, keyAbortLive: keyAbortLive) != nil else {
            return .skip(.noAbortSource)
        }
        return .run(chosen)
    }
}
