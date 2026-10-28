import XCTest
@testable import VoiceDictationLogic

final class GhostTextAbbreviationTests: XCTestCase {
    func testAbbreviationLedNameIsNotCutToAStub() { XCTAssertEqual(GhostTextPrompt.clean("Dr. Smith"), "Dr. Smith") }
    func testAbbreviationInsideSuggestionIsNotCut() { XCTAssertEqual(GhostTextPrompt.clean("U.S. market"), "U.S. market") }
    func testMrKeepsSurname() { XCTAssertEqual(GhostTextPrompt.clean("Mr. Jones"), "Mr. Jones") }
    func testSentenceEndStillCuts() { XCTAssertEqual(GhostTextPrompt.clean("go home. Then"), "go home") }
}
