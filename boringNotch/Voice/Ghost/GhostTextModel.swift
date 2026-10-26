//
//  GhostTextModel.swift
//  boringNotch
//

import FoundationModels

/// The only file that talks to FoundationModels. Every call uses a fresh session, so the
/// 4K window never fills across requests, and nothing is prewarmed before he asks for text.
@available(macOS 26.0, *)
final class GhostTextModel {
    static let shared = GhostTextModel()

    private init() {}

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Returns the raw reply, or nil on any error (overflow, guardrail, cancellation).
    func complete(_ prompt: String) async -> String? {
        let session = LanguageModelSession(instructions: GhostTextPrompt.instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 24))
            return response.content
        } catch {
            return nil
        }
    }
}
