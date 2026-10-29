import AppKit

/// NSSpellChecker's on-device completions for mid-word ghost text (#58). Main actor: NSSpellChecker is AppKit.
/// It is given only the partial word, never the rest of the field, and it logs nothing.
@MainActor
struct GhostWordSpeller: GhostWordCompleting {
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()

    func completions(forPartial partial: String) -> [String] {
        NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
                                          in: partial, language: nil, inSpellDocumentWithTag: Self.tag) ?? []
    }
}
