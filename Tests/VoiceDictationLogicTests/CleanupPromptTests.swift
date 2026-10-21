import XCTest
@testable import VoiceDictationLogic

/// Scope 4 (backend): the instructions carry the rules, the tone and the dictionary,
/// and stay free of networking words (invariant I1).
final class CleanupPromptTests: XCTestCase {
    func testCarriesTheToneLine() {
        let text = CleanupPrompt.instructions(tone: .email, dictionary: [])
        XCTAssertTrue(text.contains(AppTone.email.instructionLine), text)
    }

    func testCarriesEveryDictionaryWord() {
        let text = CleanupPrompt.instructions(tone: .neutral, dictionary: ["Jun", "Kubernetes"])
        XCTAssertTrue(text.contains("Jun"), text)
        XCTAssertTrue(text.contains("Kubernetes"), text)
    }

    func testHasNoNetworkingSymbols() {
        for tone in AppTone.allCases {
            let text = CleanupPrompt.instructions(tone: tone, dictionary: ["Jun", "Kubernetes"])
            XCTAssertEqual(NoNetworkTests.violations(in: text), [], text)
            XCTAssertFalse(text.contains("Network"), text)
        }
    }

    /// v4 speed / risks: a typed Return sends a chat message, and auto-pairing editors
    /// add brackets and quotes the user never spoke.
    func testAsksForOneParagraphWithoutLineBreaksOrInventedPunctuation() {
        let text = CleanupPrompt.instructions(tone: .neutral, dictionary: [])
        XCTAssertTrue(text.contains("Write one paragraph. No line breaks."), text)
        XCTAssertTrue(text.contains("Do not add quotation marks, brackets or backticks that were not spoken."), text)
    }

    /// The planner's 1500-character figure cannot hold 200 eight-letter words (2000 characters
    /// of words alone), so the bound here is the one that can hold. Deviation noted on the PR.
    func testStaysSmallWithTheFullDictionary() {
        let words = (0..<200).map { "word\(String(format: "%04d", $0))" }
        let text = CleanupPrompt.instructions(tone: .code, dictionary: words)
        XCTAssertLessThan(text.count, 4000)
        XCTAssertTrue(text.contains(words[199]))
    }
}
