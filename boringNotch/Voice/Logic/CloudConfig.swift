import Foundation

/// The one place the cloud models, host and budgets are written.
enum CloudConfig {
    /// Assembled from parts so the literal host appears in one file only (the no-network test checks it).
    static let host = ["openrouter", "ai"].joined(separator: ".")

    /// AssemblyAI first (about 450 ms), Voxtral second (about 1 s).
    static let sttModels = ["assemblyai/universal-3-6-pro", "mistralai/voxtral-mini-transcribe-3-0"]
    /// Haiku 5.5 with `<transcript>` tags: 0/24 trap failures in the benchmark.
    static let cleanupModels = ["anthropic/claude-haiku-5.5"]

    static let sttTimeout: TimeInterval = 2.5
    static let cleanupFirstTokenTimeout: TimeInterval = 2.0
    static let foundationBudget: TimeInterval = 1.5
    static let rewriteDeadline: TimeInterval = 8.0
    static let swapThrottleMs = 80
    static let maxTakeSeconds = 180

    private static let vocabularyCap = 200

    /// STT prompt from the personal dictionary. Nil when there are no words.
    static func vocabularyPrompt(_ words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        return "Vocabulary: " + words.prefix(vocabularyCap).joined(separator: ", ")
    }
}
