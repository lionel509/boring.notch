import Foundation

/// Decides whether a focused field may be read for a suggestion. This is the only gate before any text
/// reaches the prompt or the overlay.
enum GhostTextPolicy {
    static let pauseDelay: TimeInterval = 2.0
    static let maxContextChars = 1500
    static let minContextChars = 3
    static let maxSuggestionWords = 12
    static let secureSubrole = "AXSecureTextField"
    static let excludedBundleIDs: Set<String> = [
        "md.obsidian",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.apple.Terminal",
        "theboringteam.boringnotch",
    ]

    /// Which policy check refused a snapshot. Fixed tokens for the log; never field text.
    enum Check: String, CaseIterable {
        case secure, bundle, noText, shortText, caretNotAtEnd, notWordBoundary
    }

    static func allows(_ s: GhostTextSnapshot) -> Bool {
        allowFailure(s) == nil
    }

    private static func allowFailure(_ s: GhostTextSnapshot) -> Check? {
        if s.isSecure || s.subrole == secureSubrole || s.role == "AXSecureTextField" { return .secure }
        if s.bundleID.isEmpty || excludedBundleIDs.contains(s.bundleID) { return .bundle }
        guard let text = s.textBeforeCaret else { return .noText }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < minContextChars { return .shortText }
        return nil
    }

    /// True when the text ends where a new suggestion may start: after whitespace or ASCII punctuation.
    static func wordBoundary(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.isWhitespace || ".,;:!?".contains(last)
    }

    /// The first content check that refuses the snapshot, or nil when all of them pass.
    static func failedCheck(_ s: GhostTextSnapshot) -> Check? {
        if let check = allowFailure(s) { return check }
        if !s.caretAtEnd { return .caretNotAtEnd }
        if !wordBoundary(s.textBeforeCaret ?? "") { return .notWordBoundary }
        return nil
    }

    /// The only trigger for a model call: an allowed field, caret at the end, both rects known, at a word boundary.
    static func shouldRequest(_ s: GhostTextSnapshot) -> Bool {
        failedCheck(s) == nil && s.caretLocation != nil && s.caretRect != nil && s.fieldRect != nil
    }
}
