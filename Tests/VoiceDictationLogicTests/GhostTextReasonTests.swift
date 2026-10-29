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

    // MARK: #47 fields: axError and app

    func testAppAndAxErrorRenderAfterInsertResult() {
        let line = GhostTextEvent.line(.dropped, callsTotal: 2, reason: .noFocusedApp,
                                       axError: -25204, app: "com.google.Chrome")
        XCTAssertEqual(line, "ghost event=dropped calls=2 reason=noFocusedApp axError=-25204 app=com.google.Chrome")
    }

    func testEmptyAppRendersAsNone() {
        let line = GhostTextEvent.line(.dropped, callsTotal: 2, reason: .xpcError, app: "")
        XCTAssertEqual(line, "ghost event=dropped calls=2 reason=xpcError app=none")
    }

    /// Privacy invariant (#47): whatever a bundle ID or a stray string contains, the line carries only
    /// `key=token` pairs drawn from `[A-Za-z0-9.-]`, and one ` app=` at most.
    func testNoLineCarriesUserTextWhateverTheAppString() throws {
        let shape = try NSRegularExpression(pattern: "^ghost( [a-zA-Z]+=-?[A-Za-z0-9.-]+)+$")
        let pool = Array("abcXYZ019 =\n\".-é字🙂".unicodeScalars)
        var state: UInt64 = 47
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        var apps = ["com.evil app=x\nghost event=accepted", "com.google.Chrome"]
        for _ in 0..<500 {
            let length = Int(next() % 301)
            var s = String.UnicodeScalarView()
            for _ in 0..<length { s.append(pool[Int(next() % UInt64(pool.count))]) }
            apps.append(String(s))
        }
        let reasons: [GhostTextEvent.Reason?] = [nil] + GhostTextEvent.Reason.allCases.map { Optional($0) }
        for event in GhostTextEvent.allCases {
            for reason in reasons {
                for app in apps {
                    for axError in [nil, -25204] as [Int?] {
                        let line = GhostTextEvent.line(event, callsTotal: 1, reason: reason,
                                                       axError: axError, app: app)
                        let range = NSRange(line.startIndex..., in: line)
                        XCTAssertNotNil(shape.firstMatch(in: line, range: range), line)
                        XCTAssertEqual(line.components(separatedBy: " app=").count - 1, 1, line)
                        let value = String(line.components(separatedBy: " app=")[1])
                        XCTAssertLessThanOrEqual(value.count, 155, line)
                    }
                }
            }
        }
    }
}
