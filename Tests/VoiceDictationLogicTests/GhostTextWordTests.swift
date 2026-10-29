import AppKit
import XCTest
@testable import VoiceDictationLogic

/// #58: finish a half-typed word from the macOS spell checker. No model, no prompt.
private struct GhostWordLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// A fake dictionary. `suffixForAll` makes every partial answer with exactly one candidate: partial + suffix.
@MainActor
final class FakeDictionary: GhostWordCompleting {
    var answers: [String: [String]] = [:]
    var suffixForAll: String? = nil
    var asked: [String] = []

    func completions(forPartial partial: String) -> [String] {
        asked.append(partial)
        if let suffixForAll { return [partial + suffixForAll] }
        return answers[partial] ?? []
    }
}

/// The real NSSpellChecker answer, as the app adapter (GhostWordSpeller) asks it (#62 round 4).
@MainActor
struct SystemSpeller: GhostWordCompleting {
    func completions(forPartial partial: String) -> [String] {
        NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
                                          in: partial, language: nil,
                                          inSpellDocumentWithTag: NSSpellChecker.uniqueSpellDocumentTag()) ?? []
    }
}

@MainActor
final class GhostTextWordTests: XCTestCase {

    /// Path to the app sources from this test file: <root>/Tests/VoiceDictationLogicTests/<file>, with `//` line comments
    /// removed (#62 round 4): a commented-out line must not satisfy a source pin.
    private func appSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slash = line.range(of: "//") else { return line }
                return line[..<slash.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The text from one marker up to another, used to read one function without parsing Swift.
    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    // MARK: - Which text is a partial word

    func testPartialWordTable() {
        let cases: [(String, String?)] = [
            ("I am hesitat", "hesitat"), ("hel", "hel"), ("he", nil), ("hello ", nil), ("(hel", "hel"),
            ("\"hel", "hel"), ("lionel@gma", nil), ("github.com/lio", nil), ("re-enter", nil), ("#hashtag", nil),
            ("abc123", nil), ("don't", nil), ("你好世界", nil),
            (String(repeating: "a", count: 25), nil),
            (String(repeating: "a", count: 24), String(repeating: "a", count: 24)),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(GhostTextWord.partialWord(text), expected, text)
        }
    }

    // MARK: - Which completion is chosen

    func testFirstUsableCandidateWins() {
        let dictionary = FakeDictionary()
        dictionary.answers["hesitat"] = ["hesitate", "hesitation"]
        XCTAssertEqual(GhostTextWord.completion(before: "I am hesitat", dictionary: dictionary), "e")

        dictionary.answers["hel"] = ["hel-p", "help me", "hxlpz", "helpful"]
        XCTAssertEqual(GhostTextWord.completion(before: "hel", dictionary: dictionary), "pful")

        dictionary.answers["doesn"] = ["doesn't"]
        XCTAssertEqual(GhostTextWord.completion(before: "doesn", dictionary: dictionary), "'t")

        dictionary.answers["tomorr"] = []
        XCTAssertNil(GhostTextWord.completion(before: "tomorr", dictionary: dictionary))
    }

    func testTypedWordFirstShowsNothing() {
        let dictionary = FakeDictionary()
        dictionary.answers["the"] = ["the", "they"]
        XCTAssertNil(GhostTextWord.completion(before: "the", dictionary: dictionary))

        dictionary.answers["Thank"] = ["Thank", "Thanks"]
        XCTAssertNil(GhostTextWord.completion(before: "Thank", dictionary: dictionary))

        dictionary.answers["inform"] = ["information", "inform"]
        XCTAssertNil(GhostTextWord.completion(before: "inform", dictionary: dictionary))
    }

    /// #62 round 2: a finished word is never extended, even when the dictionary lists a longer word first.
    func testCompleteWordIsNeverExtended() {
        let inform = FakeDictionary()
        inform.answers["inform"] = ["information", "informed", "inform"]
        XCTAssertNil(GhostTextWord.completion(before: "I will inform", dictionary: inform))

        let the = FakeDictionary()
        the.answers["the"] = ["these", "the", "they"]
        XCTAssertNil(GhostTextWord.completion(before: "look at the", dictionary: the))
    }

    /// #62 round 2: the same rule against NSSpellChecker, and the unfinished words still complete.
    func testRealSpellCheckerNeverExtendsACompleteWord() {
        // The app adapter (GhostWordSpeller) lives in the app target, so this is the same call written out here.
        struct RealSpeller: GhostWordCompleting {
            func completions(forPartial partial: String) -> [String] {
                NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
                                                  in: partial, language: nil,
                                                  inSpellDocumentWithTag: NSSpellChecker.uniqueSpellDocumentTag()) ?? []
            }
        }
        XCTAssertNil(GhostTextWord.completion(before: "I will inform", dictionary: RealSpeller()))
        XCTAssertEqual(GhostTextWord.completion(before: "I am hesitat", dictionary: RealSpeller()), "e")
        XCTAssertEqual(GhostTextWord.completion(before: "doesn", dictionary: RealSpeller()), "'t")
    }

    /// #62 round 3: informal and clipped words are never completed. The real NSSpellChecker list leaves them out and
    /// offers a longer word (lol -> lollipop), so the rule is a stop-list checked before the dictionary is asked.
    func testInformalWordsAreNeverCompleted() {
        struct SystemSpeller: GhostWordCompleting {
            func completions(forPartial partial: String) -> [String] {
                NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
                                                  in: partial, language: nil,
                                                  inSpellDocumentWithTag: NSSpellChecker.uniqueSpellDocumentTag()) ?? []
            }
        }
        XCTAssertNil(GhostTextWord.completion(before: "I wanna", dictionary: SystemSpeller()))
        XCTAssertNil(GhostTextWord.completion(before: "yup", dictionary: SystemSpeller()))
        XCTAssertNil(GhostTextWord.completion(before: "lol", dictionary: SystemSpeller()))
        XCTAssertNil(GhostTextWord.completion(before: "we outta", dictionary: SystemSpeller()))
        XCTAssertNil(GhostTextWord.completion(before: "that's crazy LOL", dictionary: SystemSpeller()))

        // The stop-list is checked before the dictionary: the fake dictionary is never asked for "lol".
        let dictionary = FakeDictionary()
        dictionary.answers["lol"] = ["lollipop"]
        XCTAssertNil(GhostTextWord.completion(before: "lol", dictionary: dictionary))
        XCTAssertTrue(dictionary.asked.isEmpty, "the dictionary was asked: \(dictionary.asked)")

        dictionary.answers["LOL"] = ["LOLLIPOP"]
        XCTAssertNil(GhostTextWord.completion(before: "LOL", dictionary: dictionary))
        XCTAssertTrue(dictionary.asked.isEmpty, "the dictionary was asked: \(dictionary.asked)")
    }

    /// #62 round 4 (rule B): a contraction typed without its apostrophe is never completed, because the dictionary offers
    /// a longer word (cant -> canton, ive -> ivermectin). The check is on the whole partial, before the dictionary is asked.
    func testContractionsAreNeverCompleted() {
        for token in ["cant", "wont", "shant", "ive", "hes", "whats", "hed", "whos", "heres"] {
            XCTAssertNil(GhostTextWord.completion(before: "I will \(token)", dictionary: SystemSpeller()), token)
        }

        let cant = FakeDictionary()
        cant.answers["cant"] = ["canton"]
        XCTAssertNil(GhostTextWord.completion(before: "cant", dictionary: cant))
        XCTAssertTrue(cant.asked.isEmpty, "the dictionary was asked: \(cant.asked)")

        let whats = FakeDictionary()
        whats.answers["Whats"] = ["WhatsApp"]
        XCTAssertNil(GhostTextWord.completion(before: "so Whats", dictionary: whats))
        XCTAssertTrue(whats.asked.isEmpty, "the dictionary was asked: \(whats.asked)")
    }

    /// #62 round 4: the words that are also English words stay with the finished-word rule, not the table. The table holds
    /// only spellings that are not words, so `hel` still completes to `p`.
    func testRealWordContractionsStayWithFinishedWordRule() {
        for word in ["ill", "well", "its", "lets", "were", "shell", "wed", "shed"] {
            XCTAssertNil(GhostTextWord.completion(before: "I will \(word)", dictionary: SystemSpeller()), word)
        }
        XCTAssertEqual(GhostTextWord.completion(before: "I will hel", dictionary: SystemSpeller()), "p")
    }

    /// #62 round 4 (rule B): the table holds only spellings that are not words, each at least minPrefix letters. It costs a
    /// completion only at the partials that are also a prefix of a common word; the list below is the measured set.
    func testContractionTableCost() {
        for entry in GhostTextWord.contractions {
            XCTAssertGreaterThanOrEqual(entry.count, GhostTextWord.minPrefix, entry)
            XCTAssertTrue(entry.allSatisfy { $0.isLetter && $0.isLowercase }, entry)
        }
        for word in ["ill", "well", "its", "lets", "were", "hell", "shell", "wed", "shed"] {
            XCTAssertFalse(GhostTextWord.contractions.contains(word), word)
        }

        let words = ["hello", "help", "hesitate", "itself", "illness", "wellness", "shelter", "wedding", "letter", "western",
                     "whose", "hedge", "canteen", "Monday", "February", "could", "would", "should", "beautiful", "follow",
                     "about", "because", "great", "give", "information", "thanks", "youth", "theory", "there", "where",
                     "wonder", "weekend", "identity", "isolate"]
        var lost: [String] = []
        for word in words {
            let lower = word.lowercased()
            for length in GhostTextWord.minPrefix..<lower.count {
                let prefix = String(lower.prefix(length))
                if GhostTextWord.contractions.contains(prefix) { lost.append(prefix) }
            }
        }
        XCTAssertEqual(lost.sorted(), ["cant", "hed", "hes", "whos"])
    }

    // MARK: - Input source (#62 round 2)

    /// A fake input source: the type the system reports, or nil when the read fails.
    private struct FakeInputSource: GhostInputSourceReading {
        var type: String?
        func currentInputSourceType() -> String? { type }
    }

    func testWordPathOnlyForPlainKeyboardLayouts() {
        let cases: [(String?, Bool)] = [
            ("TISTypeKeyboardLayout", true),
            ("TISTypeKeyboardInputMode", false),
            ("TISTypeKeyboardInputMethodWithoutModes", false),
            ("TISTypeKeyboardInputMethodModeEnabled", false),
            (nil, false),
        ]
        for (type, expected) in cases {
            XCTAssertEqual(GhostTextWord.wordPathAllowed(FakeInputSource(type: type)), expected, type ?? "nil")
        }
    }

    func testCaseMatching() {
        let dictionary = FakeDictionary()
        dictionary.answers["Hel"] = ["Help"]
        XCTAssertEqual(GhostTextWord.completion(before: "Hel", dictionary: dictionary), "p")

        dictionary.answers["HEL"] = ["help"]
        XCTAssertEqual(GhostTextWord.completion(before: "HEL", dictionary: dictionary), "P")

        dictionary.answers["iph"] = ["iPhone"]
        XCTAssertEqual(GhostTextWord.completion(before: "iph", dictionary: dictionary), "one")

        dictionary.answers["nas"] = ["NASA"]
        XCTAssertEqual(GhostTextWord.completion(before: "nas", dictionary: dictionary), "a")

        dictionary.answers["NAS"] = ["NASA"]
        XCTAssertEqual(GhostTextWord.completion(before: "NAS", dictionary: dictionary), "A")

        XCTAssertEqual(GhostTextWord.matchCase("p", typed: "H", candidate: "Help"), "p")
    }

    // MARK: - Privacy and routing invariants (generated)

    /// Generated invariant: the dictionary only ever sees the trailing 3 to 24 letters before the caret.
    func testDictionaryOnlySeesThePartialWord() {
        var rng = GhostWordLCG(state: 58)
        let pieces = ["Hello ", "wor", "Secret ", "pass", "lionel@gma", "x", "123", "你好", "\n", "(", "-",
                      "hesitat", "THE", "don'", "a"]
        var askedRuns = 0
        for _ in 0..<5000 {
            var text = ""
            for _ in 0..<Int.random(in: 1...6, using: &rng) { text += pieces.randomElement(using: &rng)! }
            let dictionary = FakeDictionary()
            dictionary.suffixForAll = "ing"
            let completion = GhostTextWord.completion(before: text, dictionary: dictionary)
            XCTAssertLessThanOrEqual(dictionary.asked.count, 1, text)
            if let partial = dictionary.asked.first {
                askedRuns += 1
                XCTAssertTrue(text.hasSuffix(partial), text)
                XCTAssertTrue(partial.allSatisfy { $0.isLetter }, partial)
                XCTAssertTrue((3...24).contains(partial.count), partial)
            }
            if let completion {
                XCTAssertTrue(completion.allSatisfy { $0.isLetter || $0 == "'" }, completion)
                XCTAssertFalse(completion.contains(where: { $0.isWhitespace }), completion)
            }
        }
        // A green check must be able to go red: the dictionary has to be asked in many runs.
        XCTAssertGreaterThan(askedRuns, 0)
    }

    /// Generated invariant: a snapshot that reaches the word path passed every gate the model path passes.
    func testWordRouteImpliesEveryModelGate() {
        var rng = GhostWordLCG(state: 5858)
        let excluded = Array(GhostTextPolicy.excludedBundleIDs)
        let bundles = excluded + ["", "com.apple.Safari", "com.apple.TextEdit", "com.hnc.Discord"]
        let subroles = ["", "AXSecureTextField", "AXSearchField"]
        let roles = ["AXTextArea", "AXTextField", "AXSecureTextField", "AXWebArea"]
        let texts: [String?] = [nil, "", "hi", "Hello wor", "Hello world ", "x)", "pass"]
        var routed = 0
        var forbidden = 0
        for _ in 0..<10000 {
            var s = GhostTextSnapshot()
            s.bundleID = bundles.randomElement(using: &rng)!
            s.appName = "App"
            s.windowTitle = "Window"
            s.subrole = subroles.randomElement(using: &rng)!
            s.role = roles.randomElement(using: &rng)!
            s.isSecure = Bool.random(using: &rng)
            s.caretAtEnd = Bool.random(using: &rng)
            s.textBeforeCaret = texts.randomElement(using: &rng)!
            if GhostTextWord.routes(s) {
                routed += 1
                XCTAssertFalse(s.isSecure)
                XCTAssertNotEqual(s.role, "AXSecureTextField")
                XCTAssertNotEqual(s.subrole, GhostTextPolicy.secureSubrole)
                XCTAssertFalse(s.bundleID.isEmpty)
                XCTAssertFalse(excluded.contains(s.bundleID))
                XCTAssertTrue(s.caretAtEnd)
                XCTAssertNotNil(s.textBeforeCaret)
                XCTAssertFalse(GhostTextPolicy.shouldRequest(s))
            }
            let text = s.textBeforeCaret ?? ""
            let isForbidden = s.isSecure || s.subrole == GhostTextPolicy.secureSubrole
                || s.role == "AXSecureTextField" || s.bundleID.isEmpty
                || excluded.contains(s.bundleID) || !s.caretAtEnd
                || text.trimmingCharacters(in: .whitespacesAndNewlines).count < GhostTextPolicy.minContextChars
            if isForbidden { forbidden += 1 }
        }
        // A green check must be able to go red: both the word route and the refusals have to be exercised.
        XCTAssertGreaterThan(routed, 0)
        XCTAssertGreaterThan(forbidden, 0)
    }

    // MARK: - Log lines and source pins

    func testWordLogLines() {
        XCTAssertEqual(GhostTextEvent.line(.word, callsTotal: 3, wordMs: 4), "ghost event=word calls=3 wordMs=4")
        XCTAssertEqual(GhostTextEvent.line(.dropped, callsTotal: 3, reason: .noWord),
                       "ghost event=dropped calls=3 reason=noWord")
    }

    func testManagerWordBranchSourcePins() throws {
        let manager = try appSource("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertTrue(manager.contains("let midWord = GhostTextWord.routes(snapshot) && GhostWordSpeller.inputSourceAllowsWord()"))
        XCTAssertTrue(manager.contains("if !midWord, let check = GhostTextPolicy.failedCheck(snapshot)"))
        XCTAssertTrue(manager.contains("midWord ? \"\" : GhostTextPrompt.build(snapshot)"))

        let refused = try XCTUnwrap(manager.range(of: "GhostInsertGate.refusedBy(role: snapshot.role"))
        let allowed = try XCTUnwrap(manager.range(of: "guard GhostInsertGate.appAllows(token: snapshot.token"))
        let branch = try XCTUnwrap(manager.range(of: "if midWord {"))
        XCTAssertLessThan(refused.lowerBound, branch.lowerBound, "the word branch sits before the allow-list")
        XCTAssertLessThan(allowed.lowerBound, branch.lowerBound, "the word branch sits before appAllows")

        let word = section(manager, from: "if midWord {", to: "} else {")
        XCTAssertTrue(word.contains("GhostWordSpeller()"))
        XCTAssertTrue(word.contains(".word"))
        XCTAssertTrue(word.contains(".noWord"))
        for banned in ["GhostTextModel", "GhostTextPrompt", "ghostTextCalls", "join("] {
            XCTAssertFalse(word.contains(banned), "the word path contains \(banned)")
        }
        XCTAssertTrue(manager.contains("pendingModelMs = spentModelMs"))
    }

    func testSpellerAdapterSourcePins() throws {
        let speller = try appSource("boringNotch/Voice/Ghost/GhostWordSpeller.swift")
        XCTAssertTrue(speller.contains("@MainActor"))
        XCTAssertTrue(speller.contains("NSSpellChecker.shared.completions(forPartialWordRange:"))
        XCTAssertTrue(speller.contains("in: partial"))
        XCTAssertTrue(speller.contains("TISCopyCurrentKeyboardInputSource"))
        XCTAssertTrue(speller.contains("kTISPropertyInputSourceType"))
        XCTAssertTrue(speller.contains("GhostTextWord.wordPathAllowed(TISInputSource())"))
        for banned in ["Logger(", "os_log", "NSLog", "print(", "GhostTextLog"] {
            XCTAssertFalse(speller.contains(banned), "the adapter contains \(banned)")
        }
    }

    // MARK: - Measurement pin

    /// The spell checker answers on the main actor, so its time is pinned: a median and a worst case over 20 prefixes.
    func testSpellCheckerCompletionIsUnderBudget() {
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        func ask(_ partial: String) -> [String] {
            NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: (partial as NSString).length),
                                              in: partial, language: nil, inSpellDocumentWithTag: tag) ?? []
        }
        let hesitat = ask("hesitat")
        XCTAssertFalse(hesitat.isEmpty, "the spell service returned no completions")
        XCTAssertTrue(hesitat.allSatisfy { $0.hasPrefix("hesitat") }, "\(hesitat)")

        _ = ask("hel")
        let prefixes = ["hel", "the", "doe", "hes", "com", "inf", "bea", "tom", "wor", "pro",
                        "con", "exp", "rec", "acc", "dif", "imp", "sen", "res", "int", "dev"]
        var times: [Double] = []
        for prefix in prefixes {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = ask(prefix)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        let median = times[times.count / 2]
        let worst = times[times.count - 1]
        print("DEMO | wordMs median=\(String(format: "%.1f", median)) max=\(String(format: "%.1f", worst))")
        XCTAssertLessThanOrEqual(median, 10)
        XCTAssertLessThanOrEqual(worst, 150)
    }
}
