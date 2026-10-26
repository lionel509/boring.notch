import XCTest
import CoreGraphics
@testable import VoiceDictationLogic

/// Diagnostics: every dropped ghost-text line says why. Reasons, policy checks and insert codes are fixed tokens.
final class GhostTextReasonTests: XCTestCase {
    private let fixedToken = "^[a-z][A-Za-z]*$"

    func testEveryReasonRendersAsAFixedToken() throws {
        let regex = try NSRegularExpression(
            pattern: "^ghost event=dropped calls=0 reason=[a-z][A-Za-z]*$")
        XCTAssertFalse(GhostTextEvent.Reason.allCases.isEmpty)
        for reason in GhostTextEvent.Reason.allCases {
            let line = GhostTextEvent.line(.dropped, callsTotal: 0, reason: reason)
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNotNil(regex.firstMatch(in: line, range: range), line)
            XCTAssertTrue(line.hasSuffix(" reason=\(reason.rawValue)"), line)
        }
    }

    func testReasonTokensHoldNoUserText() throws {
        let tokens = try NSRegularExpression(pattern: fixedToken)
        for reason in GhostTextEvent.Reason.allCases {
            let range = NSRange(reason.rawValue.startIndex..., in: reason.rawValue)
            XCTAssertNotNil(tokens.firstMatch(in: reason.rawValue, range: range), reason.rawValue)
        }
        for check in GhostTextPolicy.Check.allCases {
            let range = NSRange(check.rawValue.startIndex..., in: check.rawValue)
            XCTAssertNotNil(tokens.firstMatch(in: check.rawValue, range: range), check.rawValue)
        }
    }

    func testPolicyCheckRendersAfterReason() throws {
        let regex = try NSRegularExpression(
            pattern: "^ghost event=dropped calls=3 reason=policy check=[a-z][A-Za-z]*$")
        for check in GhostTextPolicy.Check.allCases {
            let line = GhostTextEvent.line(.dropped, callsTotal: 3, reason: .policy, check: check)
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNotNil(regex.firstMatch(in: line, range: range), line)
        }
    }

    func testInsertResultRendersAsAnInteger() throws {
        let line = GhostTextEvent.line(.dropped, callsTotal: 1, reason: .insertFailed, insertResult: 5)
        XCTAssertEqual(line, "ghost event=dropped calls=1 reason=insertFailed insertResult=5")
        let regex = try NSRegularExpression(pattern: "^ghost event=dropped calls=\\d+ reason=[a-zA-Z]+ insertResult=-?\\d+$")
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNotNil(regex.firstMatch(in: line, range: range), line)
    }

    func testPlainEventLinesAreUnchangedByTheNewFields() {
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 0), "ghost event=dropped calls=0")
        XCTAssertEqual(GhostTextEvent.line(.accepted, callsTotal: 4), "ghost event=accepted calls=4")
    }

    /// `failedCheck` must agree with `shouldRequest` plus the caret and field rect and location checks the manager runs.
    func testFailedCheckAgreesWithShouldRequest() {
        var good = GhostTextSnapshot()
        good.bundleID = "com.apple.Safari"
        good.textBeforeCaret = "the quick brown fox "
        good.caretAtEnd = true
        good.caretLocation = 20
        good.caretX = 10; good.caretY = 10; good.caretWidth = 1; good.caretHeight = 14
        good.fieldX = 0; good.fieldY = 0; good.fieldWidth = 400; good.fieldHeight = 30

        var secure = good; secure.isSecure = true
        var noBundle = good; noBundle.bundleID = ""
        var short = good; short.textBeforeCaret = "a "
        var notEnd = good; notEnd.caretAtEnd = false
        var mid = good; mid.textBeforeCaret = "the quick"
        var noLocation = good; noLocation.caretLocation = nil
        var noCaret = good; noCaret.caretHeight = nil
        var noField = good; noField.fieldHeight = nil

        XCTAssertNil(GhostTextPolicy.failedCheck(good))
        XCTAssertEqual(GhostTextPolicy.failedCheck(secure), .secure)
        XCTAssertEqual(GhostTextPolicy.failedCheck(noBundle), .bundle)
        XCTAssertEqual(GhostTextPolicy.failedCheck(short), .shortText)
        XCTAssertEqual(GhostTextPolicy.failedCheck(notEnd), .caretNotAtEnd)
        XCTAssertEqual(GhostTextPolicy.failedCheck(mid), .notWordBoundary)

        for s in [good, secure, noBundle, short, notEnd, mid, noLocation, noCaret, noField] {
            let whole = GhostTextPolicy.failedCheck(s) == nil
                && s.caretLocation != nil && s.caretRect != nil && s.fieldRect != nil
            XCTAssertEqual(GhostTextPolicy.shouldRequest(s), whole)
        }
    }
}
