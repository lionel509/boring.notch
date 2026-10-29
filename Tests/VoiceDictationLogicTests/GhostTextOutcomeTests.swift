import XCTest
@testable import VoiceDictationLogic

/// #31 round 8: every outcome after `.call` logs one fixed-token line, and error values hold identifier characters only.
final class GhostTextOutcomeTests: XCTestCase {
    func testOutcomeReasonsExistAsFixedTokens() {
        let raws = ["modelError", "modelUnavailable", "modelEmpty", "cleanedAway", "overlayNoRoom", "overlayNoCaret"]
        for raw in raws {
            XCTAssertNotNil(GhostTextEvent.Reason(rawValue: raw), raw)
        }
    }

    func testDroppedOutcomeLinesRenderOneReason() {
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 2, reason: .modelEmpty),
                       "ghost event=dropped calls=2 reason=modelEmpty")
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 2, reason: .cleanedAway),
                       "ghost event=dropped calls=2 reason=cleanedAway")
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 2, reason: .overlayNoRoom),
                       "ghost event=dropped calls=2 reason=overlayNoRoom")
    }

    func testModelErrorCarriesTheValueField() {
        let value = GhostTextEvent.errorValue(typeName: "GenerationError", caseName: "guardrailViolation", code: 1)
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 5, reason: .modelError, value: value),
                       "ghost event=dropped calls=5 reason=modelError value=\"GenerationError.guardrailViolation\"")
    }

    func testBlankReplyIsModelEmpty() {
        XCTAssertEqual(GhostTextEvent.noSuggestionReason(""), .modelEmpty)
        XCTAssertEqual(GhostTextEvent.noSuggestionReason(" \n\t "), .modelEmpty)
    }

    func testNonBlankReplyThatCleanRejectsIsCleanedAway() {
        XCTAssertEqual(GhostTextEvent.noSuggestionReason("..."), .cleanedAway)
        XCTAssertEqual(GhostTextEvent.noSuggestionReason("\"\""), .cleanedAway)
    }

    func testErrorValueUsesCaseNameWhenThereIsOne() {
        XCTAssertEqual(GhostTextEvent.errorValue(typeName: "GenerationError", caseName: "guardrailViolation", code: 1),
                       "GenerationError.guardrailViolation")
    }

    func testErrorValueFallsBackToTheCodeWithoutACaseName() {
        XCTAssertEqual(GhostTextEvent.errorValue(typeName: "CancellationError", caseName: nil, code: -3),
                       "CancellationError#-3")
    }

    func testErrorValueKeepsIdentifierCharactersOnly() {
        XCTAssertEqual(GhostTextEvent.errorValue(typeName: "Foo<Bar> secret text", caseName: "x y\"z", code: 0),
                       "FooBarsecrettext.xyz")
        XCTAssertEqual(GhostTextEvent.errorValue(typeName: "<>", caseName: nil, code: 0), "none#0")
    }
}
