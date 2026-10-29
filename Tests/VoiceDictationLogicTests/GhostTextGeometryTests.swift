import XCTest
@testable import VoiceDictationLogic

private struct GeometryLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class GhostTextGeometryTests: XCTestCase {
    typealias G = GhostTextGeometry
    private let primary: CGFloat = 900

    func testToCocoaOnPrimaryDisplay() {
        let ax = CGRect(x: 100, y: 100, width: 0, height: 20)
        XCTAssertEqual(G.toCocoa(ax, primaryHeight: primary).origin.y, 780)
        XCTAssertEqual(G.toCocoa(ax, primaryHeight: primary).origin.x, 100)
    }

    /// A screen above the primary has negative AX y; a screen left of it has negative AX x.
    func testFlippedFixturesMapExactly() {
        let above = CGRect(x: 100, y: -600, width: 0, height: 20)
        XCTAssertEqual(G.toCocoa(above, primaryHeight: primary).origin.y, 1480)
        let left = CGRect(x: -1200, y: 100, width: 0, height: 20)
        let mapped = G.toCocoa(left, primaryHeight: primary)
        XCTAssertEqual(mapped.origin.x, -1200)
        XCTAssertEqual(mapped.origin.y, 780)
    }

    func testHasRoomRejectsCaretOutsideFieldVertically() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 200)
        XCTAssertFalse(G.hasRoom(caret: CGRect(x: 120, y: 400, width: 0, height: 20), field: field))
    }

    func testHasRoomRejectsCaretOutsideFieldHorizontally() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 200)
        XCTAssertFalse(G.hasRoom(caret: CGRect(x: 600, y: 150, width: 0, height: 20), field: field))
    }

    func testHasRoomRejectsLessThanMinimumRoom() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 200)
        // room = field.maxX - caret.maxX - 4 = 500 - 470 - 4 = 26 < 40
        XCTAssertFalse(G.hasRoom(caret: CGRect(x: 470, y: 150, width: 0, height: 20), field: field))
    }

    func testHasRoomAcceptsCaretWithRoom() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 200)
        XCTAssertTrue(G.hasRoom(caret: CGRect(x: 120, y: 150, width: 0, height: 20), field: field))
    }

    func testOverlayFrameIsNilWithoutRoom() {
        let field = CGRect(x: 100, y: 100, width: 400, height: 200)
        let frame = G.overlayFrame(caret: CGRect(x: 470, y: 150, width: 0, height: 20), field: field,
                                   textSize: CGSize(width: 80, height: 20), primaryHeight: primary)
        XCTAssertNil(frame)
    }

    func testOverlayFrameStaysBetweenCaretAndFieldEdge() throws {
        let caret = CGRect(x: 120, y: 150, width: 0, height: 20)
        let field = CGRect(x: 100, y: 100, width: 400, height: 200)
        // Text wider than the room is never clipped: no overlay, so nothing to accept.
        XCTAssertNil(G.overlayFrame(caret: caret, field: field,
                                    textSize: CGSize(width: 800, height: 20), primaryHeight: primary))
        let frame = try XCTUnwrap(G.overlayFrame(caret: caret, field: field,
                                                 textSize: CGSize(width: 200, height: 20), primaryHeight: primary))
        XCTAssertEqual(frame.width, 200)
        XCTAssertGreaterThanOrEqual(frame.minX, caret.maxX)
        XCTAssertLessThanOrEqual(frame.maxX, field.maxX)
    }

    /// 2,000 random field/caret/text sizes that have room: the overlay never covers text before the caret
    /// on its line and never leaves the field's x-range.
    func testRandomOverlaysNeverCoverTextOrLeaveField() {
        var rng = GeometryLCG(state: 0x29_6E0)
        func unit() -> CGFloat { CGFloat(rng.next() % 10_000) / 10_000 }
        var checked = 0
        for _ in 0..<2_000 {
            let field = CGRect(x: 1000 * unit(), y: 800 * unit(), width: 100 + 700 * unit(), height: 100 + 300 * unit())
            let caret = CGRect(x: field.minX + (field.width - 60) * unit(),
                               y: field.minY + field.height * unit(),
                               width: 2, height: 10 + 20 * unit())
            let textSize = CGSize(width: 1 + 400 * unit(), height: 8 + 30 * unit())
            guard G.hasRoom(caret: caret, field: field) else { continue }
            guard let frame = G.overlayFrame(caret: caret, field: field, textSize: textSize, primaryHeight: primary) else {
                XCTAssertGreaterThan(textSize.width, field.maxX - caret.maxX - 4, "hasRoom true, text fits, but no frame")
                continue
            }
            checked += 1
            // Back to Accessibility coordinates.
            let axMinX = frame.minX
            let axMaxX = frame.maxX
            XCTAssertFalse(axMinX < caret.maxX && axMaxX > field.minX, "overlay covers text before the caret")
            XCTAssertGreaterThanOrEqual(axMinX, field.minX)
            XCTAssertLessThanOrEqual(axMaxX, field.maxX)
        }
        // A green check must be able to go red: enough cases must have room.
        XCTAssertGreaterThan(checked, 100)
    }
}
