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

    /// The raw reply, or why there is none: unavailable, or a failed call (overflow, guardrail, cancellation).
    func complete(_ prompt: String) async -> GhostTextCompletion {
        guard isAvailable else { return .unavailable }
        let session = LanguageModelSession(instructions: GhostTextPrompt.instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 24))
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
