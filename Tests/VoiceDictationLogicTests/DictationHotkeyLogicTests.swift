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

final class DictationHotkeyLogicTests: XCTestCase {
    typealias Logic = DictationHotkeyLogic

    func testHoldEmitsStartThenStop() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.5), .stop)
        XCTAssertFalse(s.recording)
    }

    func testTapStartsHandsFree() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0), .start)
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0.1), .none)
        XCTAssertTrue(s.handsFree)
        XCTAssertTrue(s.recording)
    }

    func testTapThenTapStopsHandsFree() {
        var s = Logic.State()
        var actions: [Logic.Action] = []
        actions.append(Logic.reduce(&s, .keyDown, at: 0))
        actions.append(Logic.reduce(&s, .keyUp, at: 0.1))
        actions.append(Logic.reduce(&s, .keyDown, at: 1.0))
        actions.append(Logic.reduce(&s, .keyUp, at: 1.1))
        XCTAssertEqual(actions, [.start, .none, .stop, .none])
        XCTAssertFalse(s.recording)
    }

    func testRepeatKeyDownDuringHoldIsIgnored() {
        var s = Logic.State()
        _ = Logic.reduce(&s, .keyDown, at: 0)
        let before = s
        XCTAssertEqual(Logic.reduce(&s, .keyDown, at: 0.05), .none)
        XCTAssertEqual(s, before)
    }

    func testKeyUpWhenIdleIsNone() {
        var s = Logic.State()
        XCTAssertEqual(Logic.reduce(&s, .keyUp, at: 0), .none)
        XCTAssertEqual(s, Logic.State())
    }

    func testRandomSequencesPairStartsAndStops() {
        var rng = SplitMix64(state: 0x3D1C)
        for _ in 0..<500 {
            var s = Logic.State()
            var time: TimeInterval = 0
            var starts = 0
            var stops = 0
            let count = Int.random(in: 1...40, using: &rng)
            for _ in 0..<count {
                time += Double.random(in: 0...2, using: &rng)
                let event: Logic.Event = Bool.random(using: &rng) ? .keyDown : .keyUp
                let wasRecording = s.recording
                let action = Logic.reduce(&s, event, at: time)
                switch action {
                case .start:
                    XCTAssertFalse(wasRecording, "start emitted while recording")
                    starts += 1
                case .stop:
                    XCTAssertTrue(wasRecording, "stop emitted while idle")
                    stops += 1
                case .none:
                    break
                }
            }
            XCTAssertEqual(starts - stops, s.recording ? 1 : 0, "start/stop pairing broken")
        }
    }
}
