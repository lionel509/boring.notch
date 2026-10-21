import XCTest
@testable import VoiceDictationLogic

/// U2 / v2-3, v3-3: the streaming cleanup reads server-sent events; partial lines are buffered.
final class SSEParserTests: XCTestCase {
    func testTwoPayloadsSplitAcrossThreeFeeds() {
        var parser = SSEParser()
        var out: [String] = []
        out += parser.feed("data: {\"a\":")
        out += parser.feed("1}\n\ndata: {\"b\":2}\n")
        out += parser.feed("\n")
        XCTAssertEqual(out, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testDoneMarkerIsDropped() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("data: [DONE]\n\n"), [])
    }

    func testDeltaExtractsTheContentPiece() {
        let payload = "{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"
        XCTAssertEqual(CleanupStream.delta(payload), "Hi")
    }

    func testNullContentGivesNoDelta() {
        let payload = "{\"choices\":[{\"delta\":{\"content\":null}}]}"
        XCTAssertNil(CleanupStream.delta(payload))
    }

    func testUsageComesFromTheFinalChunk() throws {
        let payload = "{\"choices\":[],\"usage\":{\"prompt_tokens\":150,\"completion_tokens\":60,\"cost\":0.00001}}"
        let usage = try XCTUnwrap(CleanupStream.usage(payload))
        XCTAssertEqual(usage.prompt, 150)
        XCTAssertEqual(usage.completion, 60)
        XCTAssertNil(CleanupStream.usage("{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"))
    }
}
