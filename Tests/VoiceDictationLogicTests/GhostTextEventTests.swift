import XCTest
@testable import VoiceDictationLogic

final class GhostTextEventTests: XCTestCase {
    func testEveryEventLineHasTheCountedShape() throws {
        let regex = try NSRegularExpression(pattern: "^ghost event=(call|shown|accepted|dismissed|dropped|fallback) calls=\\d+$")
        XCTAssertEqual(GhostTextEvent.allCases.count, 6)
        for event in GhostTextEvent.allCases {
            let line = GhostTextEvent.line(event, callsTotal: 7)
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNotNil(regex.firstMatch(in: line, range: range), line)
            XCTAssertTrue(line.hasSuffix(" calls=7"), line)
        }
    }

    func testLineCarriesNoSuggestionOrFieldText() {
        for event in GhostTextEvent.allCases {
            let line = GhostTextEvent.line(event, callsTotal: 0)
            XCTAssertEqual(line.split(separator: " ").count, 3, line)
        }
    }
}
