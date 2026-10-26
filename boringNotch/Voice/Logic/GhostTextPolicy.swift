import Foundation

/// Decides whether a focused field may be read for a suggestion. This is the only gate before any text
/// reaches the prompt, the overlay, the notch or the pasteboard.
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
}
