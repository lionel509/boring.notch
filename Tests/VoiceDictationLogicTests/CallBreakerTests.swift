import XCTest
@testable import VoiceDictationLogic

// Breaker regressions for PR #23 (round 1). Each one fails on the PR as it stood at bb53d94.
final class CallBreakerTests: XCTestCase {
    typealias Logic = CallPromptLogic

    private let zoom = DetectedCall(id: "zoom", name: "Zoom", pid: 10, viaBrowser: false)

    // F2: one prompt window per call. A re-grab inside the first 15 s may re-show the prompt;
    // after the window it counts as answered `.no` until the call is forgotten through endGrace.
    func testBreakerRegrabWithinOnePromptWindowIsOnePrompt() {
        var s = Logic.State()
        XCTAssertEqual(Logic.update(&s, calls: [zoom], muted: [], at: 0), [.show(zoom)])
        XCTAssertEqual(Logic.update(&s, calls: [], muted: [], at: 5), [.hide(zoom)])
        XCTAssertEqual(Logic.update(&s, calls: [zoom], muted: [], at: 8), [.show(zoom)])
        XCTAssertEqual(Logic.update(&s, calls: [], muted: [], at: 9), [.hide(zoom)])
        XCTAssertEqual(Logic.update(&s, calls: [zoom], muted: [], at: 20), [],
                       "re-grab after the 15 s window prompted again")
        XCTAssertEqual(Logic.update(&s, calls: [], muted: [], at: 25), [])
        XCTAssertEqual(Logic.update(&s, calls: [zoom], muted: [], at: 30), [],
                       "a later re-grab prompted again")
    }

    // F1: the specific services outrank the bare words, and a Meet title is not renamed by another tab.
    func testBreakerRealMeetWindowIsNotMisnamedByAnotherTab() {
        let call = CallApps.browserCall(titles: ["Discord help - Google Search", "Meet - Weekly sync"], pid: 41)
        XCTAssertEqual(call?.id, "meet", "the Meet call was named \(call?.name ?? "nil")")
    }
}
