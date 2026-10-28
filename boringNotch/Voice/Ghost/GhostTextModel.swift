//
//  GhostTextModel.swift
//  boringNotch
//

import Foundation
import FoundationModels

/// What one model call came back with. `.failed` carries the error's type and case token, never its text.
enum GhostTextCompletion {
    case reply(String)
    case failed(value: String)
    case unavailable
}

/// The only file that talks to FoundationModels. Every call uses its own session, so the 4K window never fills across
/// requests; the next one is prewarmed while he types in an app that isn't excluded.
@available(macOS 26.0, *)
@MainActor
final class GhostTextModel {
    static let shared = GhostTextModel()

    private var next: LanguageModelSession?

    private init() {}

    /// Builds the next call's session ahead and loads the model, so the call after a pause starts warm. Sends no user text.
    func prewarm() {
        guard isAvailable, next == nil else { return }
        let session = LanguageModelSession(instructions: GhostTextPrompt.instructions)
        session.prewarm()
        next = session
    }

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The raw reply, or why there is none: unavailable, or a failed call (overflow, guardrail, cancellation).
    func complete(_ prompt: String) async -> GhostTextCompletion {
        guard isAvailable else { return .unavailable }
        let session = next ?? LanguageModelSession(instructions: GhostTextPrompt.instructions)
        next = nil
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 8))
            return .reply(response.content)
        } catch {
            // The case name is the text before any associated value, so the payload (which may hold prompt text) is dropped.
            let caseName: String? = (error as? LanguageModelSession.GenerationError).map { generation in
                String(String(describing: generation).prefix(while: { $0 != "(" }))
            }
            return .failed(value: GhostTextEvent.errorValue(
                typeName: String(describing: type(of: error)), caseName: caseName, code: (error as NSError).code))
        }
    }
}
