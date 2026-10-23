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

final class CallPromptLogicTests: XCTestCase {
    typealias Logic = CallPromptLogic
    typealias Effect = CallPromptLogic.Effect

    private let zoom = DetectedCall(id: "zoom", name: "Zoom", pid: 10, viaBrowser: false)
    private let discord = DetectedCall(id: "discord", name: "Discord", pid: 12, viaBrowser: false)
    private let meet = DetectedCall(id: "meet", name: "Google Meet", pid: 11, viaBrowser: true)

    private func update(_ s: inout Logic.State, _ calls: [DetectedCall], muted: Set<String> = [], at now: TimeInterval) -> [Effect] {
        Logic.update(&s, calls: calls, muted: muted, at: now)
    }

    private func answer(_ s: inout Logic.State, _ a: CallAnswer, muted: Set<String> = [], at now: TimeInterval) -> [Effect] {
        Logic.answer(&s, a, muted: muted, at: now)
    }

    // MARK: Examples

    func testNewCallIsShown() {
        var s = Logic.State()
        XCTAssertEqual(update(&s, [zoom], at: 0), [.show(zoom)])
        XCTAssertEqual(s.pending, zoom)
    }

    func testYesHidesAndBeginsThenReleaseEnds() {
        var s = Logic.State()
        _ = update(&s, [zoom], at: 0)
        XCTAssertEqual(answer(&s, .yes, at: 1), [.hide(zoom), .begin(zoom)])
        XCTAssertEqual(update(&s, [], at: 2), [.end(zoom)])
    }

    func testBackWithinGraceBeginsWithoutShowing() {
        var s = Logic.State()
        _ = update(&s, [zoom], at: 0)
        _ = answer(&s, .yes, at: 1)
        _ = update(&s, [], at: 2)
        XCTAssertEqual(update(&s, [zoom], at: 62), [.begin(zoom)])
    }

    func testBackAfterGraceShowsAgain() {
        var s = Logic.State()
        _ = update(&s, [zoom], at: 0)
        _ = answer(&s, .yes, at: 1)
        _ = update(&s, [], at: 2)
        XCTAssertEqual(update(&s, [zoom], at: 123), [.show(zoom)])
    }

    func testNoThenReleaseAndReturnWithinGraceIsSilent() {
        var s = Logic.State()
        _ = update(&s, [zoom], at: 0)
        XCTAssertEqual(answer(&s, .no, at: 1), [.hide(zoom)])
        XCTAssertEqual(update(&s, [], at: 2), [])
        XCTAssertEqual(update(&s, [zoom], at: 10), [])
    }

    func testMutedCallIsNeverShown() {
        var s = Logic.State()
        XCTAssertEqual(update(&s, [zoom], muted: ["zoom"], at: 0), [])
        XCTAssertNil(s.pending)
    }

    func testNeverHidesMutesAndShowsTheNextCall() {
        var s = Logic.State()
        _ = update(&s, [zoom, discord], at: 0)
        XCTAssertEqual(answer(&s, .never, at: 1), [.hide(zoom), .mute("zoom"), .show(discord)])
    }

    func testTwoCallsAtOnceShowOneThenTheOther() {
        var s = Logic.State()
        XCTAssertEqual(update(&s, [zoom, discord], at: 0), [.show(zoom)])
        XCTAssertEqual(answer(&s, .no, at: 1), [.hide(zoom), .show(discord)])
    }

    func testStaleTimeoutIsIgnored() {
        var s = Logic.State()
        _ = update(&s, [zoom], at: 0)
        XCTAssertEqual(Logic.timeout(&s, callID: "discord", muted: [], at: 1), [])
        XCTAssertEqual(s.pending, zoom)
        XCTAssertEqual(Logic.timeout(&s, callID: "zoom", muted: [], at: 15), [.hide(zoom)])
    }

    func testReleaseWhilePendingHides() {
        var s = Logic.State()
        _ = update(&s, [zoom], at: 0)
        XCTAssertEqual(update(&s, [], at: 1), [.hide(zoom)])
        XCTAssertNil(s.pending)
    }

    func testDuplicateIDsCollapseToOne() {
        var s = Logic.State()
        let dupe = DetectedCall(id: "zoom", name: "Zoom", pid: 99, viaBrowser: false)
        XCTAssertEqual(update(&s, [zoom, dupe], at: 0), [.show(zoom)])
        XCTAssertEqual(s.live.count, 1)
    }

    // MARK: Invariants

    /// Random update / answer / timeout steps over four call ids. The effects must keep the prompt and
    /// transcription bookkeeping consistent at every step.
    func testPromptInvariantsHoldOverRandomRuns() {
        var rng = SplitMix64(state: 0x22_0C0A)
        let pool = ["a", "b", "c", "d"].enumerated().map { index, id in
            DetectedCall(id: id, name: id.uppercased(), pid: Int32(index), viaBrowser: false)
        }

        for _ in 0..<3000 {
            var s = Logic.State()
            var now: TimeInterval = 0
            var balance: [String: Int] = [:]
            var firstShown: [String: TimeInterval] = [:]

            for _ in 0..<40 {
                now += Double.random(in: 0...200, using: &rng)
                let muted = Set(pool.map(\.id).filter { _ in Bool.random(using: &rng) })
                let before = s
                let effects: [Effect]

                switch Int.random(in: 0..<3, using: &rng) {
                case 0:
                    let live = pool.filter { _ in Bool.random(using: &rng) }.shuffled(using: &rng)
                    effects = Logic.update(&s, calls: live, muted: muted, at: now)
                case 1:
                    let a: CallAnswer = [.yes, .no, .never].randomElement(using: &rng)!
                    effects = Logic.answer(&s, a, muted: muted, at: now)
                default:
                    let id = pool.randomElement(using: &rng)!.id
                    effects = Logic.timeout(&s, callID: id, muted: muted, at: now)
                }

                for effect in effects {
                    switch effect {
                    case let .show(call):
                        XCTAssertFalse(muted.contains(call.id), "showed muted \(call.id)")
                        XCTAssertNil(s.answers[call.id], "showed already-answered \(call.id)")
                        // One prompt window per call: a re-show stays within promptTimeout of the first show,
                        // unless the reducer forgot the call during this step (its release had expired).
                        if let r = before.releasedAt[call.id], now - r >= Logic.endGrace { firstShown[call.id] = nil }
                        if let first = firstShown[call.id] {
                            XCTAssertLessThan(now - first, Logic.promptTimeout, "re-prompted \(call.id) after its window")
                        } else {
                            firstShown[call.id] = now
                        }
                    case let .begin(call):
                        balance[call.id, default: 0] += 1
                        XCTAssertLessThanOrEqual(balance[call.id]!, 1, "begin twice for \(call.id)")
                    case let .end(call):
                        balance[call.id, default: 0] -= 1
                        XCTAssertGreaterThanOrEqual(balance[call.id]!, 0, "end without begin for \(call.id)")
                    case .hide, .mute:
                        break
                    }
                }

                // A window ends when the reducer forgets the call (askedAt cleared), whether or not it showed again.
                for call in pool where s.askedAt[call.id] == nil { firstShown[call.id] = nil }
                if let pending = s.pending {
                    XCTAssertNotNil(s.live[pending.id], "pending is not live: \(pending.id)")
                }
                for call in pool {
                    let open = balance[call.id] ?? 0
                    XCTAssertEqual(open == 1, s.transcribing.contains(call.id), "transcribing out of step for \(call.id)")
                }
            }
        }
    }
}
