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

    /// `mode` and `takeSeconds` default to the plain case so existing callers keep their behaviour.
    static func decide(
        field: FocusedField?, cloudOn: Bool, hasKey: Bool, cleanupOn: Bool, keyAbortLive: Bool,
        mode: SpeakerMode = .onlyMe, takeSeconds: Double = 0
    ) -> Decision {
        guard let field else { return .skip(.noField) }
        let chosen = RewriteMechanism.choose(field: field)
        if field.secure || field.role == "AXSecureTextField" || chosen == .none { return .skip(.secureField) }
        // #17 U1: labels would be reflowed away by a rewrite, and the WAV is cut at the cloud cap.
        if mode == .everyoneLabelled { return .skip(.labelled) }
        if takeSeconds > Double(CloudConfig.maxTakeSeconds) { return .skip(.tooLong) }
        guard (cloudOn && hasKey) || cleanupOn else { return .skip(.cleanupOff) }
        guard RewriteMechanism.effective(chosen, caretReadable: field.caret >= 0, keyAbortLive: keyAbortLive) != nil else {
            return .skip(.noAbortSource)
        }
        return .run(chosen)
    }
}
