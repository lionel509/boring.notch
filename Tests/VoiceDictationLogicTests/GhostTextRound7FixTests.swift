import Foundation
import XCTest
@testable import VoiceDictationLogic

/// Regression tests for the round-7 breaker findings on PR #31.
final class GhostTextRound7FixTests: XCTestCase {

    // MARK: clean(): replies with no words are not suggestions

    func testCodeFenceReplyIsNotASuggestion() {
        XCTAssertNil(GhostTextPrompt.clean("```\nhello\n```"))
    }

    func testQuoteOnlyReplyIsNotASuggestion() {
        XCTAssertNil(GhostTextPrompt.clean("\"\"\""))
        XCTAssertNil(GhostTextPrompt.clean("\""))
        XCTAssertNil(GhostTextPrompt.clean("'"))
    }

    func testEllipsisAndRuleRepliesAreNotSuggestions() {
        XCTAssertNil(GhostTextPrompt.clean("..."))
        XCTAssertNil(GhostTextPrompt.clean("* * *"))
        XCTAssertNil(GhostTextPrompt.clean("\u{200B}"))
    }

    func testQuotedReplyWithTrailingPeriodLosesQuotes() {
        XCTAssertEqual(GhostTextPrompt.clean("\"world\"."), "world")
    }

    func testQuotedPhrasesKeepTheirQuotes() {
        XCTAssertEqual(GhostTextPrompt.clean("\"Yes\" or \"no\""), "\"Yes\" or \"no\"")
    }

    // MARK: decide(): synthetic events

    private func event(_ keyCode: Int, flags: UInt64 = 0, synthetic: Bool, chars: String = "a") -> GhostTextLogic.KeyEvent {
        GhostTextLogic.KeyEvent(keyCode: keyCode, flags: flags, isKeyDown: true, isAutorepeat: false,
                                isSynthetic: synthetic, characters: chars)
    }

    func testSyntheticTypingDismissesVisibleOverlay() {
        XCTAssertEqual(GhostTextLogic.decide(event(0, synthetic: true), suggestionVisible: true), .dismiss)
    }

    func testSyntheticArrowDismissesVisibleOverlay() {
        XCTAssertEqual(GhostTextLogic.decide(event(123, synthetic: true, chars: "\u{F702}"), suggestionVisible: true), .dismiss)
    }

    func testSyntheticEventsIgnoredWhenNothingVisible() {
        XCTAssertEqual(GhostTextLogic.decide(event(0, synthetic: true), suggestionVisible: false), .ignore)
    }

    func testSyntheticOptionTabNeverAccepts() {
        let optionTab = event(48, flags: GhostTextLogic.optionMask, synthetic: true, chars: "\t")
        XCTAssertEqual(GhostTextLogic.decide(optionTab, suggestionVisible: true), .ignore)
    }
}
