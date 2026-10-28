import XCTest
@testable import VoiceDictationLogic

/// #47: the helper says why a read failed; the app classifies the raced reply into a snapshot or a fixed reason.
final class GhostSnapshotReadTests: XCTestCase {
    private let textEdit = #"{"bundleID":"com.apple.TextEdit","appName":"TextEdit","textBeforeCaret":"hello wor","caretLocation":9,"caretAtEnd":true,"caretX":10,"caretY":10,"caretWidth":1,"caretHeight":14,"fieldX":0,"fieldY":0,"fieldWidth":400,"fieldHeight":30}"#
    private let fallback = #"{"bundleID":"com.google.Chrome","appName":"Chrome","textBeforeCaret":"hello wor","caretLocation":9,"caretAtEnd":true,"caretX":10,"caretY":10,"caretWidth":1,"caretHeight":14,"fieldX":0,"fieldY":0,"fieldWidth":400,"fieldHeight":30,"focusVia":"frontmost","axError":-25212}"#

    func testTimeoutIsXPCTimeout() {
        let timedOut: String?? = nil
        XCTAssertEqual(GhostSnapshotRead.classify(timedOut, frontmostBundleID: "x"),
                       .failed(.xpcTimeout, axError: nil))
    }

    func testNilReplyIsXPCError() {
        let xpcError: String?? = .some(nil)
        XCTAssertEqual(GhostSnapshotRead.classify(xpcError, frontmostBundleID: "x"),
                       .failed(.xpcError, axError: nil))
    }

    func testHelperFailureTokensMapToTheirReasons() {
        XCTAssertEqual(classify(#"{"failure":"untrusted"}"#), .failed(.untrusted, axError: nil))
        XCTAssertEqual(classify(#"{"failure":"noFocusedApp","axError":-25204}"#),
                       .failed(.noFocusedApp, axError: -25204))
        XCTAssertEqual(classify(#"{"failure":"encodeFailed"}"#), .failed(.encodeFailed, axError: nil))
    }

    func testUnknownFailureValuesAreDecodeFailed() {
        // "policy" is a real Reason but not a helper token; "a b" and a non-string are not tokens at all.
        XCTAssertEqual(classify(#"{"failure":"policy"}"#), .failed(.decodeFailed, axError: nil))
        XCTAssertEqual(classify(#"{"failure":"a b"}"#), .failed(.decodeFailed, axError: nil))
        XCTAssertEqual(classify(#"{"failure":5}"#), .failed(.decodeFailed, axError: nil))
    }

    func testNonObjectJSONIsDecodeFailed() {
        XCTAssertEqual(classify("not json"), .failed(.decodeFailed, axError: nil))
        XCTAssertEqual(classify("[]"), .failed(.decodeFailed, axError: nil))
    }

    func testDirectReadIsASnapshotWhateverTheFrontmostApp() {
        let expected = GhostTextSnapshot.decode(textEdit)!
        XCTAssertEqual(GhostSnapshotRead.classify(.some(textEdit), frontmostBundleID: "com.apple.Safari"),
                       .snapshot(expected, viaFrontmost: false, axError: nil))
    }

    func testFrontmostFallbackIsUsedWhenTheAppMatches() {
        let expected = GhostTextSnapshot.decode(fallback)!
        XCTAssertEqual(GhostSnapshotRead.classify(.some(fallback), frontmostBundleID: "com.google.Chrome"),
                       .snapshot(expected, viaFrontmost: true, axError: -25212))
    }

    func testFrontmostFallbackIsRefusedWhenTheAppDiffers() {
        XCTAssertEqual(GhostSnapshotRead.classify(.some(fallback), frontmostBundleID: "com.apple.Safari"),
                       .failed(.notFrontmost, axError: -25212))
    }

    func testFrontmostFallbackIsRefusedWithoutAFrontmostApp() {
        XCTAssertEqual(GhostSnapshotRead.classify(.some(fallback), frontmostBundleID: nil),
                       .failed(.notFrontmost, axError: -25212))
    }

    func testNoReasonTokenNamedNoSnapshotRemains() {
        XCTAssertNil(GhostTextEvent.Reason(rawValue: "noSnapshot"))
    }

    func testHelperFailuresAreTheOnlyTokensTheHelperMayUse() {
        XCTAssertEqual(GhostSnapshotRead.helperFailures, [.untrusted, .noFocusedApp, .encodeFailed])
    }

    // MARK: wire pin against the helper source

    /// Path to the app sources from this test file: <root>/Tests/VoiceDictationLogicTests/<file>.
    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text from one marker up to another, used to read one function without parsing Swift.
    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    func testHelperSourceEmitsEveryFailureTokenAndTheFallbackKeys() throws {
        let helper = try appSource("BoringNotchXPCHelper/FocusedTextReader.swift")
        for reason in GhostSnapshotRead.helperFailures {
            XCTAssertTrue(helper.contains("\"\(reason.rawValue)\""), reason.rawValue)
        }
        for token in ["failure", "axError", "focusVia", "frontmost", "frontmostApplication", "AXUIElementCreateApplication"] {
            XCTAssertTrue(helper.contains(token), token)
        }
    }

    func testHelperSnapshotJSONNeverReturnsNil() throws {
        let helper = try appSource("BoringNotchXPCHelper/FocusedTextReader.swift")
        let body = section(helper, from: "static func snapshotJSON", to: "private static func")
        XCTAssertFalse(body.isEmpty)
        XCTAssertFalse(body.contains("return nil"), body)
    }

    private func classify(_ json: String) -> GhostSnapshotRead {
        GhostSnapshotRead.classify(.some(json), frontmostBundleID: "com.apple.Safari")
    }
}
