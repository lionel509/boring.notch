import XCTest
@testable import VoiceDictationLogic

final class GhostTextPromptTests: XCTestCase {
    func testContextKeepsLastMaxChars() {
        let text = String(repeating: "a", count: 2000) + "END"
        let ctx = GhostTextPrompt.context(text)
        XCTAssertEqual(ctx.count, GhostTextPolicy.maxContextChars)
        XCTAssertTrue(ctx.hasSuffix("END"))
    }

    func testBuildExactString() {
        var s = GhostTextSnapshot()
        s.bundleID = "com.apple.Safari"
        s.appName = "Safari"
        s.windowTitle = "GitHub"
        s.role = "AXTextArea"
        s.textBeforeCaret = "Hello wor"
        XCTAssertEqual(
            GhostTextPrompt.build(s),
            "App: Safari\nWindow: GitHub\nText so far (continue from the end):\nHello wor"
        )
    }

    func testBuildIsNilForForbiddenSnapshot() {
        var s = GhostTextSnapshot()
        s.bundleID = "md.obsidian"
        s.textBeforeCaret = "Hello world"
        XCTAssertNil(GhostTextPrompt.build(s))
    }

    func testCleanNilAndBlank() {
        XCTAssertNil(GhostTextPrompt.clean(nil))
        XCTAssertNil(GhostTextPrompt.clean("  "))
    }

    func testCleanStripsQuotes() {
        XCTAssertEqual(GhostTextPrompt.clean("\"hello world\"\n"), "hello world")
        XCTAssertEqual(GhostTextPrompt.clean("`hello`"), "hello")
        XCTAssertEqual(GhostTextPrompt.clean("“hello there”"), "hello there")
    }

    func testCleanCapsWords() {
        let twenty = (1...20).map { "w\($0)" }.joined(separator: " ")
        let expected = (1...GhostTextPolicy.maxSuggestionWords).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(GhostTextPrompt.clean(twenty), expected)
    }

    func testCleanKeepsFirstLineOnly() {
        XCTAssertEqual(GhostTextPrompt.clean("first line\nsecond"), "first line")
    }

    /// Round 7 join: one space only after a letter, digit or .,;:!? when the suggestion starts with a letter or digit.
    func testJoinRound7Table() {
        let rows: [(String, String, String)] = [
            ("Hello", "world", " world"),
            ("Hello ", "world", "world"),
            ("Hello,", "world", " world"),
            ("Done.", "Next", " Next"),
            ("(", "a", "a"),
            ("costs $", "5", "5"),
            ("", "x", "x"),
            ("Hi ", " there", "there"),
            ("it", "!", "!"),
        ]
        for (context, suggestion, expected) in rows {
            XCTAssertEqual(GhostTextPrompt.join(context: context, suggestion: suggestion), expected,
                           "join(\(context.debugDescription), \(suggestion.debugDescription))")
        }
    }
}
