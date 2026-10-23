import XCTest
@testable import VoiceDictationLogic

// Boundary pins for the F2 prompt window (PR #23, round 2). The window is promptTimeout (15 s) from the first show.
final class CallBreakerEdgeTests: XCTestCase {
    typealias Logic = CallPromptLogic

    private let zoom = DetectedCall(id: "zoom", name: "Zoom", pid: 10, viaBrowser: false)

    // Shown at 0, released at 5, back at `back`. Inside the window the prompt is shown again; at and after it, not.
    private func reshow(atReturn back: TimeInterval) -> [Logic.Effect] {
        var s = Logic.State()
        XCTAssertEqual(Logic.update(&s, calls: [zoom], muted: [], at: 0), [.show(zoom)])
        XCTAssertEqual(Logic.update(&s, calls: [], muted: [], at: 5), [.hide(zoom)])
        return Logic.update(&s, calls: [zoom], muted: [], at: back)
    }

    func testBreakerEdgeReshowAt14Point9IsAllowed() {
        XCTAssertEqual(reshow(atReturn: 14.9), [.show(zoom)])
    }

    func testBreakerEdgeNoReshowAt15Point0() {
        XCTAssertEqual(reshow(atReturn: 15.0), [])
    }

    func testBreakerEdgeNoReshowAt15Point1() {
        XCTAssertEqual(reshow(atReturn: 15.1), [])
    }
}
