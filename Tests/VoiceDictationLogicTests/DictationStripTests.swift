import XCTest
@testable import VoiceDictationLogic

/// Scope 3 (size) and invariant I4: the strip's width comes from one function, and every
/// failure headline fits the message cell.
final class DictationStripTests: XCTestCase {
    /// The compact footprint is the music live activity's: two 12 pt cells plus 20 pt.
    func testCompactFootprintIsTheMusicFootprint() {
        XCTAssertEqual(DictationStrip.extraWidth(side: 12, showsMessage: false, showsMode: false), 44)
    }

    /// Only a failure or a model download adds one message cell.
    func testMessageCellAddsOneMessageWidth() {
        XCTAssertEqual(DictationStrip.extraWidth(side: 12, showsMessage: true), 194)
        XCTAssertEqual(DictationStrip.messageWidth, 150)
    }

    /// #17 U4: the mode pill is one more cell beside the bars, and it adds only its own width.
    func testModePillAddsOneModePillWidth() {
        XCTAssertEqual(
            DictationStrip.extraWidth(side: 12, showsMessage: false, showsMode: true),
            44 + DictationStrip.modePillWidth)
        XCTAssertEqual(
            DictationStrip.extraWidth(side: 12, showsMessage: false, showsMode: false), 44)
        XCTAssertGreaterThan(DictationStrip.modePillWidth, 0)
    }

    /// #17 U4: a tap on the pill cycles Me → Them → All → Me, the order the plan gives.
    func testModePillCyclesMeThemAll() {
        XCTAssertEqual(DictationStrip.nextMode(after: .onlyMe), .everyoneButMe)
        XCTAssertEqual(DictationStrip.nextMode(after: .everyoneButMe), .everyoneLabelled)
        XCTAssertEqual(DictationStrip.nextMode(after: .everyoneLabelled), .onlyMe)
    }

    /// #17 U4: the pill reads Me / Them / All for the three modes.
    func testModePillLabels() {
        XCTAssertEqual(DictationStrip.modeLabel(.onlyMe), "Me")
        XCTAssertEqual(DictationStrip.modeLabel(.everyoneButMe), "Them")
        XCTAssertEqual(DictationStrip.modeLabel(.everyoneLabelled), "All")
    }

    /// #17 U4: the chin reserves the pill's width while a take records (not while the model downloads).
    func testChinReservesThePillWhileRecording() throws {
        let chin = try source("boringNotch/ContentView.swift")
        XCTAssertTrue(chin.contains("showsMode: dictationShowsMode"), "the chin does not reserve the pill's width")
        XCTAssertTrue(chin.contains("private var dictationShowsMode: Bool"), "the pill flag is missing")
    }

    /// #17 U4: the activity draws the pill from the shared mode key and writes the cycled value back.
    func testModePillIsWiredToTheModeKey() throws {
        let text = try source("boringNotch/Voice/VoiceDictationLiveActivity.swift")
        XCTAssertTrue(text.contains("@Default(.dictationSpeakerMode)"), "the pill does not read the mode key")
        XCTAssertTrue(text.contains("DictationStrip.nextMode(after:"), "the tap does not cycle through DictationStrip")
        XCTAssertTrue(text.contains(".onTapGesture"), "the pill has no tap")
    }

    func testHeadlineStopsAtTheFirstPeriodOrColon() {
        XCTAssertEqual(DictationStrip.headline("Mic blocked. See Settings"), "Mic blocked")
        XCTAssertEqual(
            DictationStrip.headline("Copied (clipboard replaced). Helper not responding"),
            "Copied (clipboard replaced)"
        )
        XCTAssertEqual(DictationStrip.headline("Nothing heard"), "Nothing heard")
        XCTAssertEqual(DictationStrip.headline("Engine: restarting"), "Engine")
    }

    /// Every failure literal in VoiceDictationManager must fit the 28-character headline.
    /// Red on the default branch: "Speech model still downloading" is 30 characters.
    func testEveryFailureHeadlineFitsTheMessageCell() throws {
        let literals = try failureLiterals()
        XCTAssertGreaterThanOrEqual(literals.count, 8, "expected the failure literals, found \(literals.count)")
        for literal in literals {
            let headline = DictationStrip.headline(literal)
            XCTAssertLessThanOrEqual(headline.count, DictationStrip.headlineMax, "\(literal) -> \(headline)")
        }
    }

    /// v3-1: no transcript text in the notch. The live text is gone from both owners of the strip.
    func testNoTranscriptTextInTheNotch() throws {
        for path in ["boringNotch/ContentView.swift", "boringNotch/Voice/VoiceDictationLiveActivity.swift"] {
            XCTAssertFalse(try source(path).contains("liveText"), path)
        }
    }

    /// I6 (r5): the strip has no motion of its own. It moves with the notch on the same
    /// `.smooth` the music live activity uses, with no r4 spring names, no scale entry and
    /// no separate content animation.
    func testStripMovesWithTheNotchOnSmooth() throws {
        let text = try source("boringNotch/ContentView.swift")
        for name in ["DictationMotion.expand", "DictationMotion.collapse", "DictationMotion.content"] {
            XCTAssertFalse(text.contains(name), name)
        }
        XCTAssertFalse(text.contains("scale(scale: 0.9)"), "r4 scale entry on the dictation strip")
        XCTAssertTrue(text.contains(".animation(.smooth, value: voiceDictation.state)"), "the strip rides the notch's .smooth")
        XCTAssertTrue(text.contains("DictationStrip.extraWidth"), "the strip width still comes from DictationStrip")
    }

    /// v3-5: the refining state is a shimmer on the bars, driven by one published flag.
    func testRefiningShimmerIsWiredToTheBars() throws {
        let text = try source("boringNotch/Voice/VoiceDictationLiveActivity.swift")
        XCTAssertTrue(text.contains("voice.refining"))
        XCTAssertTrue(text.contains("repeatForever"))
    }

    private func source(_ path: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/DictationStripTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func failureLiterals() throws -> [String] {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/DictationStripTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("boringNotch/Voice/VoiceDictationManager.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let patterns = [#"fail\("([^"]+)""#, #""([^"]*Try again)""#]
        var found: [String] = []
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { found.append(String(text[r])) }
            }
        }
        return found
    }
}
