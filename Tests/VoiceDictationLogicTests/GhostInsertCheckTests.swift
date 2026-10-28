import XCTest
@testable import VoiceDictationLogic

private struct InsertLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33   // high bits: low bits of an LCG cycle too fast
    }
}

/// Behaves like an AX text field: setSelectedText replaces the selected range and moves the caret after it.
private final class FakeField: GhostTextField {
    var value: String?
    var selectionLocation: Int
    var selectionLength: Int
    var setCalls = 0
    var setResult = true
    /// Reports success but leaves the value alone (a read-back that differs).
    var ignoresSet = false

    init(value: String, location: Int, length: Int = 0) {
        self.value = value
        self.selectionLocation = location
        self.selectionLength = length
    }

    var selection: (location: Int, length: Int)? { (selectionLocation, selectionLength) }

    func setSelectedText(_ text: String) -> Bool {
        setCalls += 1
        guard setResult else { return false }
        if ignoresSet { return true }
        let ns = (value ?? "") as NSString
        value = ns.replacingCharacters(in: NSRange(location: selectionLocation, length: selectionLength), with: text)
        selectionLocation += (text as NSString).length
        selectionLength = 0
        return true
    }

    func string(location: Int, length: Int) -> String? {
        guard let value else { return nil }
        let ns = value as NSString
        guard location >= 0, length >= 0, location + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: location, length: length))
    }
}

final class GhostInsertCheckTests: XCTestCase {
    typealias C = GhostInsertCheck

    private func read(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testInsertAtEndAppends() {
        let field = FakeField(value: "Hello wor", location: 9)
        XCTAssertEqual(C.insert("ld", at: 9, into: field), .inserted)
        XCTAssertEqual(field.value, "Hello world")
    }

    func testRefusesWhenSelectionHasLength() {
        let field = FakeField(value: "Hello world", location: 2, length: 1)
        XCTAssertEqual(C.insert("X", at: 2, into: field), .refused)
        XCTAssertEqual(field.value, "Hello world")
        XCTAssertEqual(field.setCalls, 0)
    }

    func testRefusesWhenCaretMoved() {
        let field = FakeField(value: "Hello world", location: 3)
        XCTAssertEqual(C.insert("X", at: 5, into: field), .refused)
        XCTAssertEqual(field.value, "Hello world")
        XCTAssertEqual(field.setCalls, 0)
    }

    func testRefusesWhenNonBlankTextFollowsCaret() {
        let field = FakeField(value: "Hello world", location: 5)
        XCTAssertEqual(C.insert("!", at: 5, into: field), .refused)
        XCTAssertEqual(field.value, "Hello world")
        XCTAssertEqual(field.setCalls, 0)
    }

    func testWhitespaceAfterCaretIsAllowed() {
        let field = FakeField(value: "Hi  ", location: 2)
        XCTAssertEqual(C.insert(" there", at: 2, into: field), .inserted)
        XCTAssertEqual(field.value, "Hi there  ")
    }

    func testSetFailureLeavesValueUnchanged() {
        let field = FakeField(value: "Hello wor", location: 9)
        field.setResult = false
        XCTAssertEqual(C.insert("ld", at: 9, into: field), .setFailed)
        XCTAssertEqual(field.value, "Hello wor")
    }

    func testReadBackThatDiffersIsUnverified() {
        let field = FakeField(value: "Hello wor", location: 9)
        field.ignoresSet = true
        XCTAssertEqual(C.insert("ld", at: 9, into: field), .unverified)
        XCTAssertEqual(field.value, "Hello wor")
    }

    /// 5,000 seeded random fields, selections and expected locations.
    /// Invariant: refused leaves the field untouched; inserted gives exactly the spliced value.
    func testRandomFieldsEitherRefuseOrSpliceExactly() {
        var rng = InsertLCG(state: 0x29_1C5)
        let alphabet = Array("ab é\n")
        let textAlphabet = Array("xy z")
        var inserted = 0
        for _ in 0..<5_000 {
            let len = Int(rng.next() % 21)
            let value = String((0..<len).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            let ns = value as NSString
            let selLoc = Int(rng.next() % UInt64(ns.length + 1))
            let selLen = rng.next() % 4 == 0 ? 1 : 0
            let field = FakeField(value: value, location: selLoc, length: selLen)
            let expected = Int(rng.next() % UInt64(ns.length + 2))
            let text = String((0..<(1 + Int(rng.next() % 3))).map { _ in textAlphabet[Int(rng.next() % UInt64(textAlphabet.count))] })

            let result = C.insert(text, at: expected, into: field)
            switch result {
            case .refused:
                XCTAssertEqual(field.value, value)
                XCTAssertEqual(field.setCalls, 0)
            case .inserted:
                inserted += 1
                let loc = min(expected, ns.length)
                let spliced = ns.substring(to: loc) + text + ns.substring(from: loc)
                XCTAssertEqual(field.value, spliced)
            default:
                XCTFail("unexpected \(result) from a healthy fake field")
            }
        }
        // A green check must be able to go red: the insert path has to be exercised.
        XCTAssertGreaterThan(inserted, 100)
    }

    func testHelperAndAppCopiesAreByteIdentical() throws {
        let app = try read("boringNotch/Voice/Logic/GhostInsertCheck.swift")
        let helper = try read("BoringNotchXPCHelper/GhostInsertCheck.swift")
        XCTAssertEqual(app, helper)
    }

    func testHelperGhostInsertUsesTheCheckAndNeverSetsWholeValue() throws {
        let text = try read("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        XCTAssertTrue(text.contains("GhostInsertCheck.accept"))
        for line in text.components(separatedBy: "\n") where line.contains("kAXValueAttribute as CFString") {
            XCTAssertFalse(line.contains("Set"), "the helper may read the whole value, never set it: \(line)")
        }
    }

    func testManagerHasNoPasteboardOrCmdVPath() throws {
        let text = try read("boringNotch/Voice/Ghost/GhostTextManager.swift")
        for banned in ["postPasteKeystroke", "NSPasteboard", "ClipboardKeeper"] {
            XCTAssertFalse(text.contains(banned), "GhostTextManager.swift still contains \(banned)")
        }
    }

    private final class WriteThenErrorField: GhostTextField {
        var selection: (location: Int, length: Int)?
        var value: String?
        init(value: String, caret: Int) { self.value = value; self.selection = (caret, 0) }
        func setSelectedText(_ text: String) -> Bool {
            guard let v = value, let s = selection else { return false }
            let ns = v as NSString
            value = ns.substring(to: s.location) + text + ns.substring(from: s.location)
            return false
        }
        func string(location: Int, length: Int) -> String? {
            guard let v = value else { return nil }
            return (v as NSString).substring(with: NSRange(location: location, length: length))
        }
    }

    func testWriteThenErrorIsInsertedOnce() {
        let field = WriteThenErrorField(value: "Hello ", caret: 6)
        XCTAssertEqual(GhostInsertCheck.insert("world", at: 6, into: field), .inserted)
        XCTAssertEqual(field.value, "Hello world")
    }

    func testMayTypeOnlyForSetFailedWithSuccessfulNotSettableQuery() {
        for r in [GhostInsertCheck.Result.inserted, .unverified, .refused, .setFailed] {
            for q in [true, false] {
                for st in [true, false] {
                    let expected = r == .setFailed && q && !st
                    XCTAssertEqual(GhostInsertCheck.mayType(r, querySucceeded: q, settable: st), expected)
                }
            }
        }
    }

    func testHelperTypesOnlyThroughMayType() throws {
        // Round 12 (#47): typing lives inside GhostInsertCheck.accept, which gates it on mayType.
        let logic = try read("boringNotch/Voice/Logic/GhostInsertCheck.swift")
        let accept = logic.components(separatedBy: "static func accept(").last ?? ""
        XCTAssertTrue(accept.contains("mayType("), "accept must gate typing on mayType")
        let text = try read("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        let start = text.range(of: "func ghostInsert(")
        let end = text.range(of: "private struct AXGhostField")
        let body = start.flatMap { s in end.map { String(text[s.lowerBound..<$0.lowerBound]) } } ?? ""
        XCTAssertTrue(body.contains("GhostInsertCheck.accept("), "ghostInsert must call accept")
        XCTAssertEqual(body.components(separatedBy: "typeUnicode(").count - 1, 1, "one typing call in ghostInsert")
        let typed = body.range(of: "type: { typed in")?.lowerBound
        let call = body.range(of: "typeUnicode(")?.lowerBound
        XCTAssertNotNil(typed)
        if let typed, let call { XCTAssertLessThan(typed, call, "typing must sit inside the accept type closure") }
    }
}
