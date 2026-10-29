import AppKit
import Carbon

/// NSSpellChecker's on-device completions for mid-word ghost text (#58). Main actor: NSSpellChecker is AppKit.
/// It is given only the partial word, never the rest of the field, and it logs nothing.
@MainActor
struct GhostWordSpeller: GhostWordCompleting {
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()

    func completions(forPartial partial: String) -> [String] {
        NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
                                          in: partial, language: nil, inSpellDocumentWithTag: Self.tag) ?? []
    }

    /// True when the current keyboard input source is a plain layout (#62 round 2). The decision is GhostTextWord.wordPathAllowed.
    static func inputSourceAllowsWord() -> Bool {
        GhostTextWord.wordPathAllowed(TISInputSource())
    }
}

/// Reads the current input source's type through TIS (#62 round 2). Read only; nil when the property is missing.
struct TISInputSource: GhostInputSourceReading {
    func currentInputSourceType() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
