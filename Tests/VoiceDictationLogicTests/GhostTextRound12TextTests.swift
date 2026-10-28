import XCTest
@testable import VoiceDictationLogic

/// #47 round 12: suggestion text (join, dedupe, clean), the snapshot font fields, and the latency pins.
final class GhostTextRound12TextTests: XCTestCase {
    private struct TextRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func read(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - join

    func testJoinKeepsDotInsideATokenAndSpacesSentences() {
        XCTAssertEqual(GhostTextPrompt.join(context: "version 3.", suggestion: "14"), "14")
        XCTAssertEqual(GhostTextPrompt.join(context: "notes.", suggestion: "md"), "md")
        XCTAssertEqual(GhostTextPrompt.join(context: "Done.", suggestion: "Thanks"), " Thanks")
        XCTAssertEqual(GhostTextPrompt.join(context: "etc.", suggestion: "and"), " and")
        XCTAssertEqual(GhostTextPrompt.join(context: "e.g.", suggestion: "the"), " the")
        XCTAssertEqual(GhostTextPrompt.join(context: "Done.", suggestion: "thanks for"), " thanks for")
    }

    // MARK: - dedupe

    func testDedupeDropsARepeatedFirstWord() {
        XCTAssertEqual(GhostTextPrompt.dedupe(context: "see you tomorrow", suggestion: "tomorrow at noon"), "at noon")
        XCTAssertNil(GhostTextPrompt.dedupe(context: "see you tomorrow", suggestion: "tomorrow"))
        XCTAssertEqual(GhostTextPrompt.dedupe(context: "See you Tomorrow.", suggestion: "tomorrow, then"), "then")
        XCTAssertEqual(GhostTextPrompt.dedupe(context: "", suggestion: "hi there"), "hi there")
        XCTAssertEqual(GhostTextPrompt.dedupe(context: "hello", suggestion: "world"), "world")
    }

    // MARK: - clean

    func testCleanCutsAtCJKStopsAndKeepsSymbolLeads() {
        XCTAssertEqual(GhostTextPrompt.clean("好的。我们走吧。"), "好的")
        XCTAssertEqual(GhostTextPrompt.clean("$5 each"), "$5 each")
        XCTAssertEqual(GhostTextPrompt.clean("-3 degrees"), "-3 degrees")
        XCTAssertEqual(GhostTextPrompt.clean("#tag it"), "#tag it")
        XCTAssertEqual(GhostTextPrompt.clean("@name hi"), "@name hi")
        XCTAssertEqual(GhostTextPrompt.clean("(see below"), "(see below")
        XCTAssertEqual(GhostTextPrompt.clean("! :. . 3.5 dollars"), "3.5 dollars")
    }

    func testCleanInvariantOverSeededReplies() {
        let tokens = ["好的", "我们", "走吧", "hello", "3.5", "$5", "-3", "world"]
        let stops = GhostTextPolicy.suggestionStops.union(GhostTextPolicy.cjkStops).sorted().map { String($0) }
        var rng = TextRNG(state: 0x47_2026)
        for run in 0..<3000 {
            let count = Int.random(in: 1...6, using: &rng)
            var reply = ""
            for _ in 0..<count {
                reply += tokens.randomElement(using: &rng)!
                if Bool.random(using: &rng) { reply += stops.randomElement(using: &rng)! }
                if Bool.random(using: &rng) { reply += " " }
            }
            guard let out = GhostTextPrompt.clean(reply) else { continue }
            XCTAssertFalse(out.contains(where: { GhostTextPolicy.cjkStops.contains($0) }), "run \(run): \(out)")
            if let last = out.last {
                XCTAssertFalse(GhostTextPolicy.suggestionStops.union(GhostTextPolicy.cjkStops).contains(last),
                               "run \(run): ends in a stop: \(out)")
            }
            XCTAssertLessThanOrEqual(out.split(whereSeparator: { $0.isWhitespace }).count, 4, "run \(run): \(out)")
        }
    }

    // MARK: - snapshot font fields

    func testWrongTypedFontFieldsDecodeToNilAndTheRestStaysIntact() {
        let json = """
        {"bundleID":"com.apple.Safari","appName":"Safari","windowTitle":"Inbox","role":"AXTextArea",\
        "subrole":"","isSecure":false,"textBeforeCaret":"hello there","caretLocation":11,"caretAtEnd":true,\
        "fontName":12,"fontSize":"14"}
        """
        let s = GhostTextSnapshot.decode(json)
        XCTAssertNotNil(s)
        XCTAssertNil(s?.fontName)
        XCTAssertNil(s?.fontSize)
        XCTAssertEqual(s?.bundleID, "com.apple.Safari")
        XCTAssertEqual(s?.textBeforeCaret, "hello there")
        XCTAssertEqual(s?.caretLocation, 11)
        XCTAssertEqual(s?.caretAtEnd, true)
    }

    // MARK: - latency pins

    func testLatencyPins() throws {
        XCTAssertEqual(GhostTextPolicy.maxContextChars, 600)
        XCTAssertLessThan(GhostTextPrompt.instructions.count, 200)
        XCTAssertTrue(GhostTextPrompt.instructions.contains("1 to 4 words"))

        var s = GhostTextSnapshot()
        s.bundleID = "com.apple.Safari"
        s.appName = "Safari"
        s.windowTitle = String(repeating: "Ω", count: 200)
        s.textBeforeCaret = "hello there"
        s.caretAtEnd = true
        let prompt = try XCTUnwrap(GhostTextPrompt.build(s))
        XCTAssertEqual(prompt.components(separatedBy: "Ω").count - 1, 80, "window title is not capped at 80")

        let model = try read("boringNotch/Voice/Ghost/GhostTextModel.swift")
        XCTAssertTrue(model.contains("sampling: .greedy"), "model does not decode greedily")
        XCTAssertFalse(model.contains("temperature:"), "model still sets a temperature")
    }
}
