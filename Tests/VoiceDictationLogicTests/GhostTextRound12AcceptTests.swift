import XCTest
@testable import VoiceDictationLogic

/// #47 round 12: the accept write path. Web content is typed, never AX-written; native fields type only after a
/// definite failure that left the value byte-identical; the helper uses the pid the app sends.
final class GhostTextRound12AcceptTests: XCTestCase {
    private struct AcceptRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// A field whose set can write, fail, or report success without writing.
    private final class AcceptField: GhostTextField {
        var value: String?
        var selectionLocation: Int
        var setCalls = 0
        var setWrites = false
        var setReturns = false
        /// The set reports failure after writing only a proper prefix of the text (a partial write).
        var setWritesPartial = false

        init(value: String, caret: Int) {
            self.value = value
            self.selectionLocation = caret
        }

        var selection: (location: Int, length: Int)? { (selectionLocation, 0) }

        func setSelectedText(_ text: String) -> Bool {
            setCalls += 1
            if setWritesPartial {
                write(String(text.prefix(max(1, text.count / 2))))
                return false
            }
            guard setWrites else { return setReturns }
            write(text)
            return setReturns
        }

        private func write(_ text: String) {
            let ns = (value ?? "") as NSString
            value = ns.replacingCharacters(in: NSRange(location: selectionLocation, length: 0), with: text)
            selectionLocation += (text as NSString).length
        }

        func string(location: Int, length: Int) -> String? {
            let ns = (value ?? "") as NSString
            guard location >= 0, length >= 0, location + length <= ns.length else { return nil }
            return ns.substring(with: NSRange(location: location, length: length))
        }
    }

    private func read(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The text from one marker up to another, used to read one function without parsing Swift.
    private func section(_ text: String, from start: String, to end: String) -> String {
        guard let a = text.range(of: start) else { return "" }
        let rest = text[a.lowerBound...]
        guard let b = rest.range(of: end) else { return String(rest) }
        return String(rest[..<b.lowerBound])
    }

    private func count(_ text: String, _ needle: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Seeded invariant

    func testAcceptWritesAtMostOnceAndOnlyAfterTheCaretCheck() {
        let pool = ["", "hi", "the quick brown fox jumps over the", "Hello ", "你好 ", "a\u{1F600}"]
        let tails = ["", " ", "x"]
        let texts = ["lazy", " dog", "你好"]
        var rng = AcceptRNG(state: 0x47_0012)
        for run in 0..<5000 {
            let base = pool.randomElement(using: &rng)!
            let value = base + tails.randomElement(using: &rng)!
            let length = (value as NSString).length
            let caret = Int.random(in: 0...length, using: &rng)
            let expected = caret + [-1, 0, 1].randomElement(using: &rng)!
            let text = texts.randomElement(using: &rng)!
            let field = AcceptField(value: value, caret: caret)
            field.setWrites = Bool.random(using: &rng)
            field.setReturns = Bool.random(using: &rng)
            field.setWritesPartial = Int.random(in: 0..<4, using: &rng) == 0
            let typeReturns = Bool.random(using: &rng)
            let inWeb = Bool.random(using: &rng)
            let settable: Bool? = [true, false, nil].randomElement(using: &rng)!
            let readyBefore = GhostInsertCheck.ready(text, at: expected, in: field)
            let valueBefore = field.value
            var typeCalls = 0
            var valueAtType: String?
            let result = GhostInsertCheck.accept(text, at: expected, into: field, inWebArea: inWeb,
                settable: { settable },
                type: { _ in
                    typeCalls += 1
                    valueAtType = field.value
                    return typeReturns
                })
            let setWrote = field.setCalls > 0 && (field.setWrites || field.setWritesPartial)

            XCTAssertLessThanOrEqual(typeCalls, 1, "run \(run): typed more than once")
            XCTAssertLessThanOrEqual((setWrote ? 1 : 0) + typeCalls, 1, "run \(run): written twice")
            if typeCalls == 1 {
                XCTAssertEqual(valueAtType, valueBefore, "run \(run): typed after the value changed")
                XCTAssertEqual(result, typeReturns ? .typed : .focusMoved, "run \(run)")
            } else {
                XCTAssertNotEqual(result, .typed, "run \(run)")
                XCTAssertNotEqual(result, .focusMoved, "run \(run)")
            }
            if setWrote { XCTAssertEqual(typeCalls, 0, "run \(run): typed after an AX write landed") }
            if inWeb { XCTAssertEqual(field.setCalls, 0, "run \(run): AX-wrote web content") }
            if !readyBefore {
                XCTAssertEqual(field.setCalls, 0, "run \(run): wrote a field that is not ready")
                XCTAssertEqual(typeCalls, 0, "run \(run): typed into a field that is not ready")
                XCTAssertEqual(result, .refused, "run \(run)")
            }
        }
    }

    // MARK: - Examples

    func testWebFieldIsTypedAndNeverAXWritten() {
        let value = "Search for "
        let field = AcceptField(value: value, caret: (value as NSString).length)
        field.setWrites = true
        field.setReturns = true
        var typed: [String] = []
        let result = GhostInsertCheck.accept("lazy", at: (value as NSString).length, into: field, inWebArea: true,
            settable: { true },
            type: { typed.append($0); return true })
        XCTAssertEqual(result, .typed)
        XCTAssertEqual(field.setCalls, 0)
        XCTAssertEqual(typed, ["lazy"])
    }

    func testNativeFieldThatIgnoresTheSetIsUnverifiedAndNotTyped() {
        let field = AcceptField(value: "abc", caret: 3)
        field.setWrites = false
        field.setReturns = true
        var typeCalls = 0
        let result = GhostInsertCheck.accept("lazy", at: 3, into: field, inWebArea: false,
            settable: { true },
            type: { _ in typeCalls += 1; return true })
        XCTAssertEqual(result, .unverified)
        XCTAssertEqual(typeCalls, 0)
    }

    func testNativeNotSettableFieldWithFailedSetIsTyped() {
        let field = AcceptField(value: "abc", caret: 3)
        field.setWrites = false
        field.setReturns = false
        var typed: [String] = []
        let result = GhostInsertCheck.accept("lazy", at: 3, into: field, inWebArea: false,
            settable: { false },
            type: { typed.append($0); return true })
        XCTAssertEqual(result, .typed)
        XCTAssertEqual(typed, ["lazy"])
    }

    func testNativeWriteThenErrorIsInsertedAndNotTyped() {
        let field = AcceptField(value: "abc", caret: 3)
        field.setWrites = true
        field.setReturns = false
        var typeCalls = 0
        let result = GhostInsertCheck.accept("lazy", at: 3, into: field, inWebArea: false,
            settable: { false },
            type: { _ in typeCalls += 1; return true })
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(typeCalls, 0)
    }

    /// A native set that fails after writing a prefix must not be typed over (the byte-identical guard in `accept`).
    func testPartialWriteThatReportsFailureIsNotTypedOver() {
        let field = AcceptField(value: "hi ", caret: 3)
        field.setWritesPartial = true
        var typeCalls = 0
        let result = GhostInsertCheck.accept("lazy", at: 3, into: field, inWebArea: false,
            settable: { false },
            type: { _ in typeCalls += 1; return true })
        XCTAssertEqual(result, .setFailed)
        XCTAssertEqual(typeCalls, 0)
        XCTAssertEqual(field.value, "hi la")
    }

    func testWebFieldWithTextAfterTheCaretIsRefused() {
        let field = AcceptField(value: "hello world", caret: 5)
        var typeCalls = 0
        let result = GhostInsertCheck.accept("lazy", at: 5, into: field, inWebArea: true,
            settable: { true },
            type: { _ in typeCalls += 1; return true })
        XCTAssertEqual(result, .refused)
        XCTAssertEqual(typeCalls, 0)
        XCTAssertEqual(field.setCalls, 0)
    }

    // MARK: - Source pins

    func testHelperGhostInsertUsesTheSenderPidAndTheAcceptPath() throws {
        let helper = try read("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        let insert = section(helper, from: "func ghostInsert(", to: "private struct AXGhostField")
        XCTAssertTrue(insert.contains("_ frontPid: Int, with reply"), "ghostInsert does not take the caller's pid")
        XCTAssertTrue(insert.contains("pid_t(clamping: frontPid)"), "ghostInsert does not compare against the caller's pid")
        XCTAssertTrue(insert.contains("$0.pid == pid_t(clamping: frontPid)"), "sameApp is missing: the field may belong to another app")
        XCTAssertTrue(insert.contains("pidFrontmost: (still?.frontmost ?? false) && sameApp"), "the gate does not require sameApp")
        XCTAssertTrue(insert.contains("Self.isInWebArea(element)"), "ghostInsert does not check for web content")
        XCTAssertTrue(insert.contains("GhostInsertCheck.accept("), "ghostInsert does not use accept")
        XCTAssertFalse(insert.contains("GhostInsertCheck.insert("), "ghostInsert still calls insert directly")
        XCTAssertEqual(count(helper, "event.postToPid(pid)"), 1, "typed keys do not go to the field's pid")
    }

    func testFocusedTextReaderUsesTheCallersFrontApp() throws {
        let reader = try read("BoringNotchXPCHelper/FocusedTextReader.swift")
        XCTAssertFalse(reader.contains("NSWorkspace.shared.frontmostApplication"), "reader still reads a stale front app")
        XCTAssertTrue(reader.contains("AXUIElementCreateApplication(frontPid)"))
        XCTAssertTrue(reader.contains("NSRunningApplication(processIdentifier: frontPid)?.bundleIdentifier == frontBundle"))
    }

    func testXPCClientPassesTheFrontPid() throws {
        let client = try read("boringNotch/XPCHelperClient/XPCHelperClient.swift")
        XCTAssertTrue(client.contains("service.focusedTextSnapshot(frontPid, frontBundle)"))
        XCTAssertTrue(client.contains("service.ghostInsert(token, location, text, frontPid)"))
    }

    func testGhostInsertCheckCopiesAreByteIdentical() throws {
        let logic = try read("boringNotch/Voice/Logic/GhostInsertCheck.swift")
        let helper = try read("BoringNotchXPCHelper/GhostInsertCheck.swift")
        XCTAssertEqual(logic, helper)
    }
}
