import XCTest
import CoreGraphics
@testable import VoiceDictationLogic

/// #47 round 12: the suggestion is fitted to whole words before the state machine, so what is drawn is what accept
/// inserts; the front pid comes from the app; the overlay label clips instead of truncating.
final class GhostTextRound12OverlayTests: XCTestCase {
    private struct OverlayRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Caret at x 100..101 with 60 pt of room to the right of the text, as in the plan's example.
    private let caret = CGRect(x: 100, y: 100, width: 1, height: 16)
    private let field = CGRect(x: 0, y: 0, width: 165, height: 200)

    private func read(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text from one marker up to another, used to read one function without parsing Swift.
    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    private func count(_ text: String, _ needle: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - fitWords

    func testFitWordsKeepsTheWordsThatFit() {
        let eightPerChar: (String) -> CGFloat = { CGFloat(8 * $0.count) }
        XCTAssertEqual(GhostTextGeometry.fitWords(" lazy dog jumps", caret: caret, field: field, width: eightPerChar), " lazy")
        XCTAssertNil(GhostTextGeometry.fitWords("extraordinarily", caret: caret, field: field, width: eightPerChar))
        XCTAssertEqual(GhostTextGeometry.fitWords("a b", caret: caret, field: field, width: eightPerChar), "a b")
    }

    // MARK: - Seeded invariant

    func testFittedTextIsWhatAcceptInsertsAndAlwaysFits() {
        let words = ["lazy", "dog", "jumps", "你好", "世界", "fox", "a", "extraordinarily"]
        var rng = OverlayRNG(state: 0x47_3000)
        for run in 0..<3000 {
            let n = Int.random(in: 1...4, using: &rng)
            var body: [String] = []
            for _ in 0..<n { body.append(words.randomElement(using: &rng)!) }
            let text = (Bool.random(using: &rng) ? " " : "") + body.joined(separator: " ")
            let caretX = CGFloat(Int.random(in: 0...400, using: &rng))
            let caretRect = CGRect(x: caretX, y: CGFloat(Int.random(in: 0...200, using: &rng)), width: 1, height: 16)
            let fieldRect = CGRect(x: 0, y: 0, width: CGFloat(Int.random(in: 50...400, using: &rng)), height: 220)
            let k = Int.random(in: 4...14, using: &rng)
            let width: (String) -> CGFloat = { CGFloat(k * $0.count) }

            let result = GhostTextGeometry.fitWords(text, caret: caretRect, field: fieldRect, width: width)
            guard let fitted = result else {
                // Nothing fits: the first word alone is too wide, or there is no room at all.
                let first = (text.hasPrefix(" ") ? " " : "") + body[0]
                let firstFits = GhostTextGeometry.overlayFrame(caret: caretRect, field: fieldRect,
                                                               textSize: CGSize(width: width(first), height: 1),
                                                               primaryHeight: 0) != nil
                XCTAssertTrue(!firstFits || !GhostTextGeometry.hasRoom(caret: caretRect, field: fieldRect),
                              "run \(run): nothing returned although the first word fits")
                continue
            }
            XCTAssertTrue(text.hasPrefix(fitted), "run \(run): not a prefix: \(fitted)")
            let rest = text.dropFirst(fitted.count)
            XCTAssertTrue(rest.isEmpty || rest.hasPrefix(" "), "run \(run): cut inside a word: \(fitted)")
            XCTAssertFalse(fitted.contains("\u{2026}"), "run \(run): ellipsis in \(fitted)")
            XCTAssertNotNil(GhostTextGeometry.overlayFrame(caret: caretRect, field: fieldRect,
                                                           textSize: CGSize(width: width(fitted), height: 1),
                                                           primaryHeight: 0), "run \(run): does not fit: \(fitted)")
        }
    }

    // MARK: - Source pins

    func testOverlayClipsInsteadOfTruncating() throws {
        let overlay = try read("boringNotch/Voice/Ghost/GhostTextOverlay.swift")
        XCTAssertTrue(overlay.contains(".byClipping"))
        XCTAssertFalse(overlay.contains(".byTruncatingTail"), "the label still truncates to an ellipsis")
    }

    func testFetchFitsAndDedupesBeforeTheStateMachineSeesTheSuggestion() throws {
        let manager = try read("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let fetch = section(manager, from: "private func fetch(gen: Int)", to: "handle(.suggestion(suggestion, gen: gen))")
        XCTAssertTrue(manager.contains("handle(.suggestion(suggestion, gen: gen))"))
        XCTAssertTrue(fetch.contains("GhostTextGeometry.fitWords("), "fetch does not fit the suggestion to the field")
        XCTAssertTrue(fetch.contains("GhostTextPrompt.dedupe("), "fetch does not drop a repeated word")
    }

    func testOverlayMeasuresWithTheDrawingFontAndKeepsTheShownLine() throws {
        let manager = try read("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let show = section(manager, from: "private func showOverlay(", to: "private func dropOverlay(")
        XCTAssertTrue(show.contains("GhostTextOverlay.textSize(text, font: font)"))
        XCTAssertTrue(show.contains("GhostTextLog.record(.shown, latencyMs:"))
        XCTAssertFalse(show.contains("measure.intrinsicContentSize"), "showOverlay still measures with its own label")
    }

    func testManagerTakesTheFrontPidFromTheApp() throws {
        let manager = try read("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertEqual(count(manager, "focusedTextSnapshotJSON(frontPid: frontPid, frontBundle: frontBundle)"), 2)
        XCTAssertEqual(count(manager, "frontPid: Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"), 1)
        XCTAssertFalse(manager.contains("modelMs"), "the timing field came back")
    }

    func testEventAndLogFilesAreUnchangedSince31da357() throws {
        for path in ["boringNotch/Voice/Logic/GhostTextEvent.swift", "boringNotch/Voice/Ghost/GhostTextLog.swift"] {
            let root = URL(fileURLWithPath: "\(#filePath)")
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", root.path, "diff", "--quiet", "31da357", "--", path]
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0, "\(path) differs from 31da357")
        }
    }
}
