import XCTest
@testable import VoiceDictationLogic

/// U4 / I3 (rewrite safety): between swaps the inserted span is exactly one whole planner target.
final class RewritePlannerTests: XCTestCase {
    private let workedRaw = "um so send the report to jon tomorrow no wait I mean to june on thursday and um tell kevin"

    func testNormalizeCollapsesEveryWhitespaceRunIncludingNewlines() {
        XCTAssertEqual(RewritePlanner.normalize("a\n\nb  c"), "a b c")
        XCTAssertEqual(RewritePlanner.normalize("  Hey \n\n there.  "), "Hey there.")
    }

    /// The worked example from the plan: the cleaned sentence replaces the raw words it aligned to,
    /// and the raw tail after its last word is kept.
    func testWorkedExampleKeepsTheRawTailAfterTheAnchor() {
        var state = AlignState()
        let target = RewritePlanner.target(
            cleaned: "Send the report to June on Thursday.", streamEnded: false, raw: workedRaw, state: &state)
        XCTAssertEqual(target, "Send the report to June on Thursday. and um tell kevin")
        XCTAssertEqual(state.anchoredSentences, 1)

        let step = RewritePlanner.step(from: workedRaw, to: target)
        XCTAssertEqual(step?.prefixUTF16, 0)
        XCTAssertEqual(step?.suffixUTF16, " and um tell kevin".utf16.count)
        XCTAssertEqual(step?.apply(to: workedRaw), target)
    }

    func testStreamEndHasNoRawTail() {
        var state = AlignState()
        let target = RewritePlanner.target(
            cleaned: "Send the report to June on Thursday.", streamEnded: true, raw: workedRaw, state: &state)
        XCTAssertEqual(target, "Send the report to June on Thursday.")
    }

    func testStepIsNilWhenNothingChanged() {
        XCTAssertNil(RewritePlanner.step(from: "abc", to: "abc"))
    }

    func testStepFindsTheCommonPrefixAndSuffix() {
        let step = RewritePlanner.step(from: "hello there friend", to: "hello world friend")
        XCTAssertEqual(step?.prefixUTF16, 6)
        XCTAssertEqual(step?.oldMiddle, "there")
        XCTAssertEqual(step?.newMiddle, "world")
        XCTAssertEqual(step?.suffixUTF16, " friend".utf16.count)
        XCTAssertEqual(step?.oldMiddleGraphemes, 5)
        XCTAssertEqual(step?.suffixGraphemes, 7)
    }

    /// Surrogate pairs count as two UTF-16 units; the cut must land after the emoji.
    func testStepCountsSurrogatePairsAsTwoUnits() {
        let step = RewritePlanner.step(from: "a🙂b", to: "a🙂c")
        XCTAssertEqual(step?.prefixUTF16, "a🙂".utf16.count)
        XCTAssertEqual(step?.oldMiddle, "b")
        XCTAssertEqual(step?.newMiddle, "c")
        XCTAssertEqual(step?.suffixUTF16, 0)
    }

    /// I3 fuzz: feed a cleaned stream word by word through the planner and check every intermediate target.
    func testFuzzEveryIntermediateTargetIsAWholeStep() {
        var rng = PlannerRNG(seed: 21)
        let pool = ["send", "report", "june", "thursday", "kevin", "meeting", "moved", "friday", "call", "alice", "review", "draft"]
        let fillers = ["um", "uh", "so", "like", "you know", "I mean", "🙂", "cafe\u{301}", "\n"]

        for _ in 0..<300 {
            let sentenceCount = rng.int(1, 6)
            var rawTokens: [String] = []
            var cleanedSentences: [String] = []
            var anchors: [Int] = []

            for _ in 0..<sentenceCount {
                let n = rng.int(3, 6)
                // Distinct words per sentence, so each sentence's last two words match only once inside it.
                var available = pool
                var words: [String] = []
                for _ in 0..<n {
                    words.append(available.remove(at: rng.int(0, available.count - 1)))
                }
                for _ in 0..<rng.int(0, 2) {
                    rawTokens.append(fillers[rng.int(0, fillers.count - 1)])
                }
                for (i, word) in words.enumerated() {
                    rawTokens.append(word)
                    if i < n - 1, rng.int(0, 3) == 0 {
                        rawTokens.append(fillers[rng.int(0, fillers.count - 1)])
                    }
                }
                anchors.append(rawTokens.count - 1)
                let capitalized = words[0].prefix(1).uppercased() + words[0].dropFirst()
                cleanedSentences.append(([capitalized] + Array(words.dropFirst())).joined(separator: " ") + ".")
            }

            let raw = rawTokens.joined(separator: " ")
            let cleanedFull = cleanedSentences.joined(separator: " ")
            var state = AlignState()
            var committed = raw
            var cleanedSoFar = ""
            var completed = 0

            for word in cleanedFull.split(separator: " ") {
                cleanedSoFar = cleanedSoFar.isEmpty ? String(word) : cleanedSoFar + " " + word
                let previousTarget = committed
                let target = RewritePlanner.target(cleaned: cleanedSoFar, streamEnded: false, raw: raw, state: &state)

                XCTAssertFalse(target.contains("\n"), target)
                if let step = RewritePlanner.step(from: committed, to: target) {
                    XCTAssertEqual(step.apply(to: committed), target)
                    let units = Array(committed.utf16)
                    XCTAssertEqual(units.count, step.prefixUTF16 + step.oldMiddle.utf16.count + step.suffixUTF16)
                    let cut = String(decoding: units[0..<step.prefixUTF16], as: UTF16.self)
                    XCTAssertFalse(cut.contains("\u{FFFD}"), "split a surrogate pair")
                    if let index = committed.utf16.index(committed.utf16.startIndex, offsetBy: step.prefixUTF16)
                        .samePosition(in: committed) {
                        XCTAssertTrue(committed.indices.contains(index) || index == committed.endIndex, "split a grapheme")
                    }
                } else {
                    XCTAssertEqual(committed, target)
                }
                committed = target

                // Prefix-stable: the earlier target's complete sentences, run together, start the later target.
                // (Per sentence would be unsatisfiable: only the first sentence can be a prefix.)
                let completedText = SentenceSplitter.completeSentences(in: previousTarget, streamEnded: false).sentences
                    .joined(separator: " ")
                XCTAssertTrue(target.hasPrefix(completedText), "\(target) lost \(completedText)")

                if cleanedSoFar.hasSuffix(".") {
                    let expectedTail = RewritePlanner.normalize(
                        rawTokens[(anchors[completed] + 1)...].joined(separator: " "))
                    let tail = RewritePlanner.normalize(String(target.dropFirst(cleanedSoFar.count)))
                    XCTAssertEqual(tail, expectedTail, "tail after sentence \(completed)")
                    completed += 1
                    XCTAssertEqual(state.anchoredSentences, completed)
                }
            }

            let final = RewritePlanner.target(cleaned: cleanedFull, streamEnded: true, raw: raw, state: &state)
            XCTAssertEqual(final, RewritePlanner.normalize(cleanedFull))
            XCTAssertFalse(final.contains("\n"))
            if let step = RewritePlanner.step(from: committed, to: final) {
                XCTAssertEqual(step.apply(to: committed), final)
            }
        }
    }

    /// Ties go to the earliest match after the cursor (the rule the reviewer checks). A repeated pair
    /// inside the window therefore anchors early; the error stops at the next sentence anchor.
    func testRepeatedPairAnchorsToTheEarliestMatch() {
        let raw = "to june on thursday no wait to june on thursday"
        var state = AlignState()
        let target = RewritePlanner.target(
            cleaned: "Send it to June on Thursday.", streamEnded: false, raw: raw, state: &state)
        XCTAssertEqual(target, "Send it to June on Thursday. no wait to june on thursday")
    }

    func testRawWindowCoversTheWordsOfTheSentenceBeingChecked() {
        let window = RewritePlanner.rawWindow(raw: workedRaw, state: AlignState(), sentenceWords: 6)
        XCTAssertTrue(window.contains("send"), window)
        XCTAssertTrue(window.contains("june"), window)
    }
}

/// Deterministic generator local to this file (CleanupGuardTests owns `LCG`).
private struct PlannerRNG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func int(_ lo: Int, _ hi: Int) -> Int {
        lo + Int(next() % UInt64(hi - lo + 1))
    }
}
