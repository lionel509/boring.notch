import XCTest
import CoreGraphics
@testable import VoiceDictationLogic

/// #60: the gray suggestion must start where typed text would continue, on the same baseline.
final class GhostTextAlignTests: XCTestCase {
    typealias G = GhostTextGeometry
    private let primary: CGFloat = 1000

    private struct AlignRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

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

    /// The Gmail case from the photo: caret from the reader's synthesized rect, ArialMT 13 metrics.
    func testPhotoReplayPenStartsAtTheCaret() throws {
        let caret = CGRect(x: 300, y: 200, width: 0, height: 15)
        let field = CGRect(x: 100, y: 100, width: 600, height: 300)
        let ascent: CGFloat = 11.7685546875
        let descent: CGFloat = 2.7548828125
        let frame = try XCTUnwrap(G.overlayFrame(caret: caret, field: field, textWidth: 52,
                                                 ascent: ascent, descent: descent, primaryHeight: primary))
        XCTAssertEqual(frame.minX, 300, accuracy: 1e-9, "pen does not start at the caret")
        let baseline = frame.minY + G.baselineInFrame(descent: descent)
        XCTAssertEqual(baseline, primary - (207.5 + (ascent - descent) / 2), accuracy: 1e-9,
                       "baseline is not centred on the caret line")
    }

    /// 5,000 seeded carets of the two shapes the reader produces: the pen point is exactly (caret.minX, centred
    /// baseline), the frame never starts left of the caret and never leaves the field.
    func testRandomPenPointIsTheCaret() {
        var rng = AlignRNG(state: 0x60_A11)
        func unit() -> CGFloat { CGFloat(rng.next() % 10_000) / 10_000 }
        var checked = 0
        for _ in 0..<5_000 {
            let field = CGRect(x: 1000 * unit(), y: 800 * unit(), width: 100 + 700 * unit(), height: 100 + 300 * unit())
            let zeroWidth = rng.next() % 2 == 0
            let caretWidth: CGFloat = zeroWidth ? 0 : 1 + CGFloat(rng.next() % 2)
            let caret = CGRect(x: field.minX + (field.width - 60) * unit(),
                               y: field.minY + field.height * unit(),
                               width: caretWidth, height: 8 + 32 * unit())
            let ascent = 5 + 55 * unit()
            let descent = 1 + 19 * unit()
            let textWidth = 1 + 400 * unit()
            guard G.hasRoom(caret: caret, field: field) else { continue }
            guard let frame = G.overlayFrame(caret: caret, field: field, textWidth: textWidth,
                                             ascent: ascent, descent: descent, primaryHeight: primary) else { continue }
            checked += 1
            let expectedBaseline = primary - (caret.midY + (ascent - descent) / 2)
            XCTAssertEqual(frame.minY + G.baselineInFrame(descent: descent), expectedBaseline, accuracy: 1e-6,
                           "baseline is off the centred line")
            XCTAssertGreaterThanOrEqual(frame.minX, caret.minX, "frame starts left of the caret")
            XCTAssertLessThanOrEqual(frame.maxX, field.maxX, "frame leaves the field")
            XCTAssertEqual(frame.minX, caret.minX, accuracy: 1e-9, "pen is not at the caret")
        }
        // A green check must be able to go red: enough cases must have room.
        XCTAssertGreaterThan(checked, 1_000)
    }

    /// Where hasRoom is true but no frame comes back, the words really are too wide for the field.
    func testNoFrameMeansTheWordsDoNotFit() {
        var rng = AlignRNG(state: 0x60_B22)
        func unit() -> CGFloat { CGFloat(rng.next() % 10_000) / 10_000 }
        for _ in 0..<2_000 {
            let field = CGRect(x: 1000 * unit(), y: 800 * unit(), width: 100 + 700 * unit(), height: 100 + 300 * unit())
            let caret = CGRect(x: field.minX + (field.width - 60) * unit(),
                               y: field.minY + field.height * unit(),
                               width: 0, height: 10 + 20 * unit())
            let textWidth = 1 + 400 * unit()
            guard G.hasRoom(caret: caret, field: field) else { continue }
            if G.overlayFrame(caret: caret, field: field, textWidth: textWidth,
                              ascent: 10, descent: 3, primaryHeight: primary) == nil {
                XCTAssertGreaterThan(textWidth, field.maxX - caret.minX - 2, "room and text fit, but no frame")
            }
        }
    }


    /// The shown line carries eleven numeric key=value geometry pairs and nothing else: no text, no font names.
    func testShownLineCarriesOnlyNumericGeometry() {
        var rng = AlignRNG(state: 0x60_C33)
        func pick() -> CGFloat {
            switch rng.next() % 8 {
            case 0: return .nan
            case 1: return .infinity
            case 2: return -.infinity
            default: return CGFloat(Int64(bitPattern: rng.next() % 2_000_000) - 1_000_000) / 100
            }
        }
        let keys = ["caretX", "caretY", "caretW", "caretH", "frameX", "frameY", "frameW", "frameH", "asc", "desc", "pt"]
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 =,.-_")
        for _ in 0..<2_000 {
            let geometry = GhostTextEvent.Geometry(caret: CGRect(x: pick(), y: pick(), width: pick(), height: pick()),
                                                   frame: CGRect(x: pick(), y: pick(), width: pick(), height: pick()),
                                                   ascent: pick(), descent: pick(), pointSize: pick())
            let line = GhostTextEvent.line(.shown, callsTotal: 1, geometry: geometry)
            XCTAssertTrue(line.allSatisfy { allowed.contains($0) }, "line has a disallowed character: \(line)")
            let tokens = line.split(separator: " ").map(String.init)
            XCTAssertEqual(tokens.count, 3 + keys.count, "line has the wrong shape: \(line)")
            XCTAssertEqual(Array(tokens.prefix(3)), ["ghost", "event=shown", "calls=1"], line)
            for (token, key) in zip(tokens.dropFirst(3), keys) {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                XCTAssertEqual(parts.count, 2, "not key=value: \(token)")
                XCTAssertEqual(parts.first, key)
                let value = Double(parts.last ?? "")
                XCTAssertNotNil(value, "not a number: \(token)")
                XCTAssertTrue(value?.isFinite ?? false, "non-finite: \(token)")
            }
        }
    }

    // MARK: - Source pins

    func testManagerLogsTheGeometryWithoutSuggestionText() throws {
        let manager = try read("boringNotch/Voice/Ghost/GhostTextManager.swift")
        let show = section(manager, from: "private func showOverlay(", to: "private func dropOverlay(")
        let logged = section(show, from: "GhostTextLog.record(.shown", to: "\n    }")
        XCTAssertTrue(logged.contains("geometry: GhostTextEvent.Geometry(caret: caret, frame: GhostTextGeometry.toCocoa(frame, primaryHeight: primaryHeight)"),
                      "shown does not log the frame in Accessibility coordinates: \(logged)")
        XCTAssertFalse(logged.contains("text"), "the shown line is given the suggestion text: \(logged)")
        XCTAssertFalse(logged.contains("suggestion"), "the shown line is given the suggestion: \(logged)")
        XCTAssertFalse(manager.contains("probeLine"), "the probe helper is still referenced")
    }

    func testOverlayDrawsOneCoreTextLineAtAPen() throws {
        let overlay = try read("boringNotch/Voice/Ghost/GhostTextOverlay.swift")
        XCTAssertTrue(overlay.contains("ctx.textPosition = CGPoint(x: 0, y: baseline)"), "overlay does not place its pen at the baseline")
        // Whole-line match, so a suffix such as "+ 2" on the baseline line goes red.
        let lines = overlay.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("label.baseline = GhostTextGeometry.baselineInFrame(descent: -font.descender)"),
                      "overlay does not draw its baseline at baselineInFrame(descent:) with no offset")
        XCTAssertTrue(overlay.contains("CTLineDraw("), "overlay does not draw with CoreText")
        XCTAssertFalse(overlay.contains("NSTextField("), "overlay still uses a text field with its own inset")
    }
}
