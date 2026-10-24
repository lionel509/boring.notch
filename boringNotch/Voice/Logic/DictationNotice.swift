import Foundation

/// One short line for the notch's announcement sneak peek: the icon, the headline (`label`) and an
/// optional second beat (`detail`). Replaces the failure text that used to sit inside the closed strip.
struct DictationNotice: Equatable {
    let label: String
    let detail: String
    let icon: String
}

/// Maps how a take ended to the notice the user sees. Successful takes have none.
enum DictationNotices {
    /// A tap released sooner than this is a bare fn or globe press, which other features use too.
    /// Only a hold at least this long earns the "Hold fn longer" notice.
    static let minDiscardHold: TimeInterval = 0.12

    static func isDiscardWorthNotice(heldFor seconds: TimeInterval) -> Bool {
        seconds >= minDiscardHold
    }

    static func notice(for outcome: TakeOutcome, message: String) -> DictationNotice? {
        switch outcome {
        case .pasted:
            return nil
        case .enrolAccepted, .enrolQuiet:
            // Enrolment prompts are not takes: no notice.
            return nil
        case .discarded:
            return DictationNotice(label: "Hold fn longer", detail: "", icon: "mic")
        case .nothingHeard:
            return DictationNotice(label: "Didn't catch that", detail: "", icon: "mic.slash")
        case .noAudio:
            return DictationNotice(label: "Mic unavailable", detail: "", icon: "mic.slash")
        case .micSilent:
            return DictationNotice(label: "Mic blocked", detail: "Settings", icon: "mic.slash")
        case .accessDenied:
            return DictationNotice(label: "Allow mic access", detail: "Settings", icon: "mic.slash")
        case .failed:
            if message == "Needs macOS 26" {
                return DictationNotice(label: "Needs macOS 26", detail: "", icon: "exclamationmark.circle")
            }
            if message.hasPrefix("Copied") || message.hasPrefix("Clipboard") {
                let detail = message.contains("Accessibility") ? "Allow Accessibility" : "⌘V"
                return DictationNotice(label: "Copied, not pasted", detail: detail, icon: "doc.on.clipboard")
            }
            return DictationNotice(label: "Dictation failed", detail: "", icon: "exclamationmark.circle")
        }
    }
}
