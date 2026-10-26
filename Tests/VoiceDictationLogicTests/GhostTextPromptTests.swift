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

    func testJoinAddsOneSpaceAfterWord() {
        XCTAssertEqual(GhostTextPrompt.join(context: "I am going to", suggestion: "the store"), " the store")
    }

    func testJoinKeepsExistingSpace() {
        XCTAssertEqual(GhostTextPrompt.join(context: "I am going to ", suggestion: "the store"), "the store")
    }

    func testJoinNoSpaceBeforePunctuation() {
        XCTAssertEqual(GhostTextPrompt.join(context: "Hello", suggestion: ", world"), ", world")
    }

    func testJoinNoSpaceInCJK() {
        XCTAssertEqual(GhostTextPrompt.join(context: "我们明天", suggestion: "去吃饭"), "去吃饭")
    }

    func testJoinEmptyContextIsSuggestion() {
        XCTAssertEqual(GhostTextPrompt.join(context: "", suggestion: "hi"), "hi")
    }

    func testJoinNoSpaceAfterConnector() {
        XCTAssertEqual(GhostTextPrompt.join(context: "write me at lionel@", suggestion: "gmail.com"), "gmail.com")
        XCTAssertEqual(GhostTextPrompt.join(context: "https://github.com/", suggestion: "lionel509"), "lionel509")
        XCTAssertEqual(GhostTextPrompt.join(context: "we need a long-", suggestion: "term plan"), "term plan")
    }

    func testJoinNoSpaceBeforeCJKPunctuation() {
        XCTAssertEqual(GhostTextPrompt.join(context: "你好。", suggestion: "我们"), "我们")
        XCTAssertEqual(GhostTextPrompt.join(context: "こんにちは、", suggestion: "元気です"), "元気です")
        XCTAssertEqual(GhostTextPrompt.join(context: "你好，", suggestion: "我们"), "我们")
        XCTAssertEqual(GhostTextPrompt.join(context: "你好！", suggestion: "我们"), "我们")
    }

    func testJoinKoreanKeepsWordSpace() {
        XCTAssertEqual(GhostTextPrompt.join(context: "나는 친구", suggestion: "학교에 갔다"), " 학교에 갔다")
    }

    func testJoinThaiNoSpace() {
        XCTAssertEqual(GhostTextPrompt.join(context: "สวัสดี", suggestion: "ครับ"), "ครับ")
    }

    func testJoinSentenceStartKeepsSpace() {
        XCTAssertEqual(GhostTextPrompt.join(context: "Hello.", suggestion: "How"), " How")
    }

    func testJoinSpaceAfterEmojiPercentEllipsis() {
        XCTAssertEqual(GhostTextPrompt.join(context: "Thanks 😊", suggestion: "See you"), " See you")
        XCTAssertEqual(GhostTextPrompt.join(context: "I'm 100%", suggestion: "sure"), " sure")
        XCTAssertEqual(GhostTextPrompt.join(context: "Wait…", suggestion: "Then"), " Then")
    }

    func testJoinOpeningQuoteNoSpace() {
        XCTAssertEqual(GhostTextPrompt.join(context: "He said \"", suggestion: "hello"), "hello")
        XCTAssertEqual(GhostTextPrompt.join(context: "costs $", suggestion: "100"), "100")
        XCTAssertEqual(GhostTextPrompt.join(context: "She said \"Hi\"", suggestion: "and left"), " and left")
        XCTAssertEqual(GhostTextPrompt.join(context: "it's", suggestion: "fine"), " fine")
    }
}
