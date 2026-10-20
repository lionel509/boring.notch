import XCTest
@testable import VoiceDictationLogic

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class TranscriptAssemblerTests: XCTestCase {
    func testJoinsAndTrimsParts() {
        XCTAssertEqual(TranscriptAssembler.join(["Hello,", " world "]), "Hello, world")
    }

    func testPartsIgnoresVolatileTailWhenFinalized() {
        XCTAssertEqual(TranscriptAssembler.parts(finals: ["Hello"], volatileTail: "wor", finalized: true), ["Hello"])
    }

    func testPartsAppendsVolatileTailWhenNotFinalized() {
        let parts = TranscriptAssembler.parts(finals: ["Hello"], volatileTail: "world", finalized: false)
        XCTAssertEqual(parts, ["Hello", "world"])
        XCTAssertEqual(TranscriptAssembler.join(parts), "Hello world")
    }

    func testBlankVolatileTailAddsNothing() {
        XCTAssertEqual(TranscriptAssembler.parts(finals: ["Hello"], volatileTail: "", finalized: false), ["Hello"])
        XCTAssertEqual(TranscriptAssembler.parts(finals: ["Hello"], volatileTail: "  \n ", finalized: false), ["Hello"])
    }

    func testEmptyPartsGiveEmptyString() {
        XCTAssertEqual(TranscriptAssembler.join(["", "  "]), "")
    }

    func testCollapsesInternalWhitespace() {
        XCTAssertEqual(TranscriptAssembler.join(["a\n\nb"]), "a b")
    }

    func testPropertyPreservesContentAndWhitespaceShape() {
        var rng = SplitMix64(state: 0x7A11)
        let words = ["alpha", "b", "c3", "dé", "x,", "y."]
        let spaces = [" ", "  ", "\t", "\n", "\n\n", " \t "]
        for _ in 0..<300 {
            var parts: [String] = []
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                var part = ""
                for _ in 0..<Int.random(in: 0...5, using: &rng) {
                    if Bool.random(using: &rng) {
                        part += spaces.randomElement(using: &rng)!
                    } else {
                        part += words.randomElement(using: &rng)!
                    }
                }
                parts.append(part)
            }
            let result = TranscriptAssembler.join(parts)
            XCTAssertEqual(result, result.trimmingCharacters(in: .whitespacesAndNewlines),
                           "leading or trailing whitespace in \(result.debugDescription)")
            XCTAssertFalse(result.contains("  "), "double space in \(result.debugDescription)")
            XCTAssertFalse(result.contains { $0.isWhitespace && $0 != " " },
                           "non-space whitespace in \(result.debugDescription)")
            let inputChars = parts.joined().filter { !$0.isWhitespace }
            XCTAssertEqual(result.filter { !$0.isWhitespace }, inputChars,
                           "content changed for \(parts.debugDescription)")
        }
    }
}
