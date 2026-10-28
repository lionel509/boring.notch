import XCTest
@testable import VoiceDictationLogic

/// Round 11 on PR #31 (plan comment 6478380313, issue #47): short suggestions, the field's font, a 0.4 s pause with a
/// prewarmed session, latency on `shown`, bundle IDs on `notFrontmost`, and one accept line with its insertResult.
/// Symbols that do not exist before the change are pinned on the source text, so this file compiles on the red commit.
final class GhostTextRound11Tests: XCTestCase {

    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    /// A stored property of the snapshot by name, read with Mirror so the test compiles before the field exists.
    private func field<T>(_ s: GhostTextSnapshot, _ label: String, as type: T.Type) -> T? {
        Mirror(reflecting: s).children.first { $0.label == label }?.value as? T
    }

    // MARK: - Short suggestions

    /// Deterministic generator (seed 47), so a failure reproduces.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// A reply that clean() returns is at most 4 words, has no newline, and ends at no clause or sentence stop.
    func testRandomRepliesNeverLeaveAClauseOrSentenceOrMoreThanFourWords() {
        let stops: Set<Character> = [".", "!", "?", ";", ":", ",", "\u{2026}"]
        let tokens = ["see", "you", "soon", "3.5", "e.g.", "don't", "wait", "config.json", "B", "Plan", ".", "...", "!", "?", ",", ";", ":", "\u{2026}",
                      "\n", " ", "  ", "\"", "'", "`"]
        var rng = LCG(state: 47)
        for _ in 0..<1000 {
            let length = rng.below(31)
            let reply = (0..<length).map { _ in tokens[rng.below(tokens.count)] }.joined()
            guard let out = GhostTextPrompt.clean(reply) else { continue }
            XCTAssertLessThanOrEqual(out.split(whereSeparator: { $0.isWhitespace }).count, 4, "too many words: \(out.debugDescription)")
            XCTAssertFalse(out.contains("\n"), "newline in: \(out.debugDescription)")
            XCTAssertFalse(out.last.map { stops.contains($0) } ?? false, "ends at a stop: \(out.debugDescription)")
            // Round 12: a dot closing an abbreviation (dotted token or single letter) is not a sentence end.
            var previous: Character?
            var token = ""
            for ch in out {
                if ch.isWhitespace {
                    // Independent of the production predicate: the stem before the closing dot is a
                    // dotted initialism of single letters ("e.g", "U.S") or a title from the literal list.
                    let stem = token.dropLast()
                    let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
                    let initialism = parts.count >= 2 && parts.allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
                    let title = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "inc", "ltd", "co", "corp"].contains(String(stem).lowercased())
                    let abbrev = previous == "." && (initialism || title)
                    if let p = previous, stops.contains(p), !abbrev {
                        XCTFail("a stop before whitespace survived: \(out.debugDescription)")
                    }
                    token = ""
                } else { token.append(ch) }
                previous = ch
            }
        }
    }

    func testCleanCutsAtTheFourthWord() {
        XCTAssertEqual(GhostTextPrompt.clean("and then we can talk about it"), "and then we can")
    }

    func testCleanCutsAtASentenceEnd() {
        XCTAssertEqual(GhostTextPrompt.clean("see you soon. Thanks again"), "see you soon")
    }

    func testCleanCutsAtAClauseComma() {
        XCTAssertEqual(GhostTextPrompt.clean("the report, and the slides"), "the report")
    }

    func testCleanKeepsDecimalsAndNumbers() {
        XCTAssertEqual(GhostTextPrompt.clean("costs 3.5 dollars"), "costs 3.5 dollars")
    }

    func testCleanCutsAtTheFirstLine() {
        XCTAssertEqual(GhostTextPrompt.clean("Hello!\nNext"), "Hello")
    }

    func testCleanDropsATrailingEllipsis() {
        XCTAssertEqual(GhostTextPrompt.clean("wait\u{2026}"), "wait")
    }

    func testCleanTrimsTrailingStopsAfterACut() {
        XCTAssertEqual(GhostTextPrompt.clean("e.g.!"), "e.g")
    }

    func testCleanSkipsLeadingPunctuationBeforeTheFirstWord() {
        XCTAssertEqual(GhostTextPrompt.clean("! :. . 3.5 dollars"), "3.5 dollars")
    }

    func testCleanReturnsNilWhenOnlyLeadingPunctuationIsLeft() {
        XCTAssertNil(GhostTextPrompt.clean("`! :`"))
    }

    /// Behavioural checks on the Round 11 signatures (added after the change; the red commit could not call them).
    func testFontSizeUsesTheFieldFontInRangeAndFallsBackOtherwise() {
        XCTAssertEqual(GhostTextGeometry.fontSize(fieldFontSize: 13, caretHeight: 30), 13)
        XCTAssertEqual(GhostTextGeometry.fontSize(fieldFontSize: 6, caretHeight: 30), 6)
        XCTAssertEqual(GhostTextGeometry.fontSize(fieldFontSize: 72, caretHeight: 30), 72)
        let fallback = GhostTextGeometry.fontSize(caretHeight: 30)
        let bads: [Double?] = [nil, 0, -1, 5.9, 72.1, .nan, .infinity]
        for bad in bads {
            XCTAssertEqual(GhostTextGeometry.fontSize(fieldFontSize: bad, caretHeight: 30), fallback, "\(String(describing: bad))")
        }
    }

    func testLatencyIsWholeMillisecondsAndNeverNegative() {
        XCTAssertEqual(GhostTextEvent.latencyMs(from: 10, to: 11.2345), 1235)
        XCTAssertEqual(GhostTextEvent.latencyMs(from: 5, to: 4), 0)
        XCTAssertEqual(GhostTextEvent.line(.shown, callsTotal: 3, latencyMs: 950), "ghost event=shown calls=3 latencyMs=950")
    }

    func testNotFrontmostLineCarriesBothBundles() {
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 0, reason: .notFrontmost, axError: -25204,
                                           app: "com.example.Other", snapshotApp: "com.apple.Safari"),
                       "ghost event=dropped calls=0 reason=notFrontmost axError=-25204 app=com.example.Other snapshotApp=com.apple.Safari")
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 0, snapshotApp: "a b/c"), "ghost event=dropped calls=0 snapshotApp=abc")
    }

    func testCleanReturnsNilWithoutWords() {
        XCTAssertNil(GhostTextPrompt.clean("..."))
    }

    func testQuotedWordWithPeriodLosesQuotesAndPeriod() {
        XCTAssertEqual(GhostTextPrompt.clean("\"world\"."), "world")
    }

    func testSuggestionCapIsFourWords() {
        XCTAssertEqual(GhostTextPolicy.maxSuggestionWords, 4)
    }

    func testSuggestionStopsAreDeclared() throws {
        let policy = try appSource("boringNotch/Voice/Logic/GhostTextPolicy.swift")
        XCTAssertTrue(policy.contains("static let suggestionStops: Set<Character> = [\".\", \"!\", \"?\", \";\", \":\", \",\", \"\\u{2026}\"]"),
                      "suggestionStops is missing or has other characters")
    }

    func testInstructionsAskForOneToFourWords() {
        XCTAssertTrue(GhostTextPrompt.instructions.contains("1 to 4 words"), GhostTextPrompt.instructions)
        XCTAssertFalse(GhostTextPrompt.instructions.contains("12"), GhostTextPrompt.instructions)
    }

    func testModelCapsResponseTokensAtEightGreedyAndPrewarms() throws {
        let model = try appSource("boringNotch/Voice/Ghost/GhostTextModel.swift")
        XCTAssertTrue(model.contains("maximumResponseTokens: 8"), "response cap is not 8")
        XCTAssertTrue(model.contains("sampling: .greedy"), "decoding is not greedy")
        XCTAssertTrue(model.contains("session.prewarm()"), "the next session is not prewarmed")
        XCTAssertTrue(model.contains("next ?? LanguageModelSession("), "complete does not take the prewarmed session")
        XCTAssertTrue(model.contains("func prewarm()"), "prewarm() is missing")
    }

    // MARK: - Pause

    func testPauseIsZeroPointFourSeconds() {
        XCTAssertEqual(GhostTextPolicy.pauseDelay, 0.4)
    }

    // MARK: - Font

    func testFontSizeComesFromTheFieldInTheClampedRange() throws {
        let geometry = try appSource("boringNotch/Voice/Logic/GhostTextGeometry.swift")
        XCTAssertTrue(geometry.contains("static func fontSize(fieldFontSize: Double?, caretHeight: CGFloat) -> CGFloat"),
                      "the field-font size function is missing")
        XCTAssertTrue(geometry.contains("s >= 6, s <= 72"), "the field font size is not clamped to 6...72")
    }

    func testSnapshotCarriesFontNameAndSize() {
        let json = #"{"bundleID":"com.apple.Safari","fontName":"ArialMT","fontSize":13}"#
        let s = GhostTextSnapshot.decode(json)
        XCTAssertEqual(field(s!, "fontName", as: String.self), "ArialMT")
        XCTAssertEqual(field(s!, "fontSize", as: Double.self), 13)
    }

    func testSnapshotWithoutFontHasNone() {
        let s = GhostTextSnapshot.decode(#"{"bundleID":"com.apple.Safari"}"#)
        XCTAssertNil(field(s!, "fontName", as: String.self))
        XCTAssertNil(field(s!, "fontSize", as: Double.self))
    }

    func testFontFieldsAreDeclaredAndDecoded() throws {
        let snapshot = try appSource("boringNotch/Voice/Logic/GhostTextSnapshot.swift")
        XCTAssertTrue(snapshot.contains("var fontName: String? = nil"))
        XCTAssertTrue(snapshot.contains("var fontSize: Double? = nil"))
        XCTAssertTrue(snapshot.contains("decodeIfPresent(String.self, forKey: .fontName)"))
        XCTAssertTrue(snapshot.contains("decodeIfPresent(Double.self, forKey: .fontSize)"))
    }

    func testFontNeverReachesThePrompt() throws {
        let prompt = try appSource("boringNotch/Voice/Logic/GhostTextPrompt.swift")
        XCTAssertFalse(prompt.contains("fontName"), "the font name would reach the model")
        XCTAssertFalse(prompt.contains("fontSize"), "the font size would reach the model")
    }

    // MARK: - Helper reads AXFont

    func testHelperReadsTheFontBeforeTheCaretWithAFallback() throws {
        let reader = try appSource("BoringNotchXPCHelper/FocusedTextReader.swift")
        XCTAssertTrue(reader.contains("fontBeforeCaret(focused, ns: ns, caretEnd: caretEnd)"))
        XCTAssertTrue(reader.contains("\"AXAttributedStringForRange\""), "the helper does not ask for the attributed string")
        XCTAssertTrue(reader.contains("\"AXFont\""), "the helper does not read AXFont")
        XCTAssertTrue(reader.contains("dict[\"fontName\"] = font.name"))
        XCTAssertTrue(reader.contains("dict[\"fontSize\"] = font.size"))
    }

    func testOverlayTakesTheFieldFont() throws {
        let overlay = try appSource("boringNotch/Voice/Ghost/GhostTextOverlay.swift")
        XCTAssertTrue(overlay.contains("func show(_ text: String, frame: CGRect, font: NSFont)"))
        XCTAssertTrue(overlay.contains("label.font = font"))
    }

    // MARK: - Latency

    func testLatencyIsMeasuredFromTheLastKeystroke() throws {
        let event = try appSource("boringNotch/Voice/Logic/GhostTextEvent.swift")
        XCTAssertTrue(event.contains("static func latencyMs(from start: TimeInterval, to end: TimeInterval) -> Int"))
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let overlay = section(manager, from: "private func showOverlay(", to: "/// Logs the one reason")
        XCTAssertTrue(overlay.contains("GhostTextLog.record(.shown, latencyMs:"), "shown does not carry latencyMs")
    }

    func testTheManagerRecordsTheLastKeystrokeTime() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertTrue(manager.contains("lastTypedAt = ProcessInfo.processInfo.systemUptime"))
        XCTAssertTrue(manager.contains("GhostTextModel.shared.prewarm()"))
    }

    // MARK: - notFrontmost names both apps

    /// A helper read whose bundle is Safari, while the app's frontmost app is something else.
    private let safariFallback = #"{"bundleID":"com.apple.Safari","appName":"Safari","textBeforeCaret":"hello wor","caretLocation":9,"caretAtEnd":true,"caretX":10,"caretY":10,"caretWidth":1,"caretHeight":14,"fieldX":0,"fieldY":0,"fieldWidth":400,"fieldHeight":30,"focusVia":"frontmost","axError":-25204}"#

    func testNotFrontmostCarriesTheSnapshotBundle() {
        let read = GhostSnapshotRead.classify(.some(safariFallback), frontmostBundleID: "com.example.Other")
        let text = String(describing: read)
        XCTAssertTrue(text.contains(".notFrontmost"), text)
        XCTAssertTrue(text.contains("snapshotApp: Optional(\"com.apple.Safari\")"), text)
    }

    func testMatchingFrontmostStillSnapshots() {
        let read = GhostSnapshotRead.classify(.some(safariFallback), frontmostBundleID: "com.apple.Safari")
        XCTAssertTrue(String(describing: read).hasPrefix("snapshot("), String(describing: read))
    }

    func testNotFrontmostLineNamesBothBundles() throws {
        let event = try appSource("boringNotch/Voice/Logic/GhostTextEvent.swift")
        XCTAssertTrue(event.contains("snapshotApp: String? = nil, latencyMs: Int? = nil"))
        XCTAssertTrue(event.contains("out += \" snapshotApp=\\(appToken(snapshotApp))\""))
        let read = try appSource("boringNotch/Voice/Logic/GhostSnapshotRead.swift")
        XCTAssertTrue(read.contains(".failed(.notFrontmost, axError: axError, snapshotApp: snapshot.bundleID)"))
    }

    // MARK: - Privacy

    func testNoGhostLogLineInTheManagerCarriesFieldTextOrFont() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let banned = ["textBeforeCaret", "fontName", "windowTitle", "appName", "suggestion", "cleaned", "before"]
        let lines = manager.components(separatedBy: "\n").filter { $0.contains("GhostTextLog.record(") }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            for word in banned {
                XCTAssertFalse(line.contains(word), "a log line carries \(word): \(line)")
            }
        }
    }

    func testLogFilesHaveNoFontWords() throws {
        for path in ["boringNotch/Voice/Logic/GhostTextEvent.swift", "boringNotch/Voice/Ghost/GhostTextLog.swift"] {
            let text = try appSource(path)
            XCTAssertFalse(text.contains("font"), "\(path) mentions a font")
        }
    }

    // MARK: - Round-9 pins that must survive the change

    func testOverlayRoomAndCaretDropsLogOnlyTheirOwnReason() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let overlay = section(manager, from: "private func showOverlay(", to: "/// Logs the one reason")
        XCTAssertTrue(overlay.contains("dropOverlay(.overlayNoRoom)"))
        XCTAssertTrue(overlay.contains("dropOverlay(.overlayNoCaret)"))
        XCTAssertFalse(overlay.contains("handle(.focusChanged)"))
    }

    func testFetchCancelledBeforeCallLogsCancelled() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let head = section(manager, from: "private func fetch(gen: Int) async {", to: "let snapshot: GhostTextSnapshot")
        XCTAssertTrue(head.contains("GhostTextLog.record(.dropped, reason: .cancelled)"),
                      "the cancel right after the XPC race logs nothing")
        let tail = section(manager, from: "guard GhostInsertGate.appAllows(token: snapshot.token", to: "Defaults[.ghostTextCalls] += 1")
        XCTAssertTrue(tail.contains("GhostTextLog.record(.dropped, reason: .cancelled)"),
                      "the cancel before .call logs nothing")
    }

    func testOneAcceptKeyWritesOneLineWithItsInsertResult() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let attempt = section(manager, from: "private func attemptInsert(", to: "private let ghostTapCallback")
        XCTAssertFalse(attempt.contains("GhostTextLog.record("), "attemptInsert still logs; one key must write one line")
        let insert = section(manager, from: "private func insert(", to: "private func attemptInsert(")
        XCTAssertEqual(insert.components(separatedBy: "GhostTextLog.record(").count - 1, 1,
                       "insert must write exactly one line")
        XCTAssertTrue(insert.contains("insertResult: outcome.result"))
    }
}
