import Foundation
import FoundationModels

/// On-device cleanup (Apple Intelligence) for when the cloud is off or fails. One instance per take,
/// because a `LanguageModelSession` keeps its own history.
@available(macOS 26.0, *)
final class TranscriptCleanup {
    enum Outcome: Equatable {
        case cleaned(String)
        case fellBack(CleanupSkip)
    }

    private let session: LanguageModelSession

    init?(instructions: String) {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        session = LanguageModelSession(instructions: instructions)
    }

    /// Cleans `raw` within `budget` seconds. Anything that fails or is rejected by `CleanupGuard`
    /// falls back to the caller's current text.
    func clean(_ raw: String, budget: TimeInterval) async -> Outcome {
        let session = self.session
        let outer: String?? = await TimeoutRace.run(seconds: budget) { () -> String? in
            try? await session.respond(to: CleanupPrompt.userMessage(raw)).content
        }
        guard let inner = outer else { return .fellBack(.timeout) }
        guard let text = inner else { return .fellBack(.error) }
        let cleaned = CleanupGuard.normalize(text)
        if cleaned.isEmpty { return .fellBack(.empty) }
        guard CleanupGuard.accept(raw: raw, cleaned: cleaned) else { return .fellBack(.guardRejected) }
        return .cleaned(cleaned)
    }
}
