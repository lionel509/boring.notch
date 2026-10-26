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

    static func allows(_ s: GhostTextSnapshot) -> Bool {
        if s.isSecure || s.subrole == secureSubrole || s.role == "AXSecureTextField" { return false }
        if s.bundleID.isEmpty || excludedBundleIDs.contains(s.bundleID) { return false }
        guard let text = s.textBeforeCaret else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minContextChars
    }

    /// True when the text ends where a new suggestion may start: after whitespace or ASCII punctuation.
    static func wordBoundary(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.isWhitespace || ".,;:!?".contains(last)
    }

    /// The only trigger for a model call: an allowed field, caret at the end, both rects known, at a word boundary.
    static func shouldRequest(_ s: GhostTextSnapshot) -> Bool {
        allows(s) && s.caretAtEnd && s.caretLocation != nil && s.caretRect != nil && s.fieldRect != nil
            && wordBoundary(s.textBeforeCaret ?? "")
    }
}
