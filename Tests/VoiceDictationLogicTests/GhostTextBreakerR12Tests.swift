import XCTest
@testable import VoiceDictationLogic

/// Round 12 review (#31, fix 1): a dot ends a sentence unless it closes a title or a dotted initialism.
/// "Plan B", "config.json" and "wait..." are not abbreviations, so the next sentence must be cut.
final class GhostTextBreakerR12Tests: XCTestCase {
    func testSingleLetterEndsASentence() { XCTAssertEqual(GhostTextPrompt.clean("Plan B. Then we"), "Plan B") }
    func testDottedFileNameEndsASentence() { XCTAssertEqual(GhostTextPrompt.clean("config.json. Then restart"), "config.json") }
    func testEllipsisEndsASentence() { XCTAssertEqual(GhostTextPrompt.clean("wait... what"), "wait") }
    func testVersionNumberEndsASentence() { XCTAssertEqual(GhostTextPrompt.clean("version 3.5. Then"), "version 3.5") }
}
