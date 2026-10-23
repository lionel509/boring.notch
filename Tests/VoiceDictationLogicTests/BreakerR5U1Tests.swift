import XCTest
@testable import VoiceDictationLogic

/// Breaker round 5, unit U1 (visual), against PR #15 head 6049c2b.
/// Source-reading tests. A red test is a break of the r5 invariant "the strip rides the notch's
/// own .smooth animation and has no motion of its own".
final class BreakerR5U1Tests: XCTestCase {
    private let strip = "boringNotch/Voice/VoiceDictationLiveActivity.swift"

    /// B1: the strip's contents run no animation of their own. RefiningShimmer starts a separate
    /// `withAnimation(...repeatForever)` on the bars while the cloud pass runs.
    func testBreakStripContentsHaveNoAnimationOfTheirOwn() throws {
        let text = try source(strip)
        XCTAssertFalse(text.contains("withAnimation"),
                       "RefiningShimmer.onAppear runs its own withAnimation on the bars during refining")
        XCTAssertFalse(text.contains("repeatForever"),
                       "the shimmer sweep repeats on its own clock, a second motion inside the strip")
    }

    /// B2: no AppKit spinner in the strip. `ProgressView` spins on its own clock. The plan keeps it
    /// for the model download only, so this is red by design. The reviewer decides whether to accept it.
    func testBreakStripHasNoSystemSpinner() throws {
        XCTAssertFalse(try source(strip).contains("ProgressView"),
                       "the download state draws an AppKit spinner that rotates on its own animation")
    }

    /// B3: no per-glyph content transition. The mic, checkmark and exclamation swap with a symbol
    /// effect (a scale and fade of the glyph) that is not the notch's own animation. Plan keeps it.
    func testBreakStripGlyphsSwapWithoutASymbolEffect() throws {
        XCTAssertFalse(try source(strip).contains("contentTransition"),
                       "glyph swaps run a symbol effect of their own instead of the notch's .smooth")
    }

    private func source(_ path: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/BreakerR5U1Tests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
