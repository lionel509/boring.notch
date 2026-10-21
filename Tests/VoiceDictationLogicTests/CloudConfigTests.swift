import XCTest
@testable import VoiceDictationLogic

/// U2 / v2-5, v4 speed budget: the one place the cloud models, host and timeouts are written.
final class CloudConfigTests: XCTestCase {
    func testHostIsOpenRouter() {
        XCTAssertEqual(CloudConfig.host, "openrouter.ai")
    }

    /// v4 consequence: AssemblyAI first (about 450 ms), Voxtral second (about 1 s).
    func testSTTModelsAssemblyAIFirstThenVoxtral() {
        XCTAssertEqual(CloudConfig.sttModels, ["assemblyai/universal-3-6-pro", "mistralai/voxtral-mini-transcribe-3-0"])
    }

    func testCleanupModelsGeminiFlashLiteFirstThenNano() {
        XCTAssertEqual(CloudConfig.cleanupModels, ["google/gemini-2.5-flash-lite", "openai/gpt-4.1-nano"])
    }

    func testBudgetsMatchThePlan() {
        XCTAssertEqual(CloudConfig.sttTimeout, 2.5)
        XCTAssertEqual(CloudConfig.cleanupFirstTokenTimeout, 2.0)
        XCTAssertEqual(CloudConfig.foundationBudget, 1.5)
        XCTAssertEqual(CloudConfig.rewriteDeadline, 8.0)
        XCTAssertEqual(CloudConfig.swapThrottleMs, 80)
        XCTAssertEqual(CloudConfig.maxTakeSeconds, 180)
    }

    func testVocabularyPromptIsNilWhenThereAreNoWords() {
        XCTAssertNil(CloudConfig.vocabularyPrompt([]))
    }

    func testVocabularyPromptFormatsTheWords() {
        XCTAssertEqual(CloudConfig.vocabularyPrompt(["a", "b", "c"]), "Vocabulary: a, b, c")
    }

    func testVocabularyPromptCapsAtTwoHundredWords() throws {
        let words = (0..<201).map { "w\($0)" }
        let prompt = try XCTUnwrap(CloudConfig.vocabularyPrompt(words))
        XCTAssertEqual(prompt.components(separatedBy: ", ").count, 200)
        XCTAssertTrue(prompt.hasSuffix("w199"), prompt.suffix(20).description)
        XCTAssertFalse(prompt.contains("w200"))
    }
}
