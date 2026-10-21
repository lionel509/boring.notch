import XCTest
@testable import VoiceDictationLogic

/// Scope 5 (phase 1): manual words plus words he corrected often enough to trust.
final class PersonalDictionaryTests: XCTestCase {
    func testParseSplitsOnCommasAndNewlinesAndDedupesKeepingFirstSpellingAndOrder() {
        let words = PersonalDictionary.parseManual("Jun, Kubernetes\nkubernetes,  , Jun\n")
        XCTAssertEqual(words, ["Jun", "Kubernetes"])
    }

    func testLearnedWordIsOnlyUsedAfterTwoCorrections() {
        XCTAssertEqual(PersonalDictionary.words(manual: "", learned: ["warp": 1]), [])
        XCTAssertEqual(PersonalDictionary.words(manual: "", learned: ["warp": 2]), ["warp"])
    }

    func testManualWordsComeFirstAndAreNotRepeatedFromLearned() {
        let words = PersonalDictionary.words(manual: "Jun", learned: ["jun": 5, "warp": 2])
        XCTAssertEqual(words, ["Jun", "warp"])
    }

    func testListIsCappedAtTwoHundred() {
        var learned: [String: Int] = [:]
        for i in 0..<250 { learned["word\(i)"] = 2 }
        let words = PersonalDictionary.words(manual: "", learned: learned)
        XCTAssertEqual(words.count, PersonalDictionary.cap)
        XCTAssertEqual(PersonalDictionary.cap, 200)
    }

    /// Learning the same word in another case bumps one entry and keeps the first spelling.
    func testLearnMergesCaseInsensitively() {
        var learned: [String: Int] = [:]
        PersonalDictionary.learn(["Jun"], into: &learned)
        PersonalDictionary.learn(["jun"], into: &learned)
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(PersonalDictionary.words(manual: "", learned: learned), ["Jun"])
        XCTAssertEqual(learned.values.first, 2)
        XCTAssertEqual(learned.keys.first, "Jun")
    }

    /// Over the cap, the lowest counts go first; the strongly learned word survives.
    func testLearnEvictsTheLowestCountsOverTheCap() {
        var learned: [String: Int] = ["keep": 5]
        for i in 0..<199 { learned["filler\(i)"] = 1 }
        PersonalDictionary.learn(["newcomer"], into: &learned)
        XCTAssertEqual(learned.count, PersonalDictionary.cap)
        XCTAssertEqual(learned["keep"], 5)
    }
}
