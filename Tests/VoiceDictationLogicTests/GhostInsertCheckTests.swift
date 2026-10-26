import XCTest
@testable import VoiceDictationLogic

private struct InsertLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
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

    /// 2,000 seeded random fields, selections and expected locations.
    /// Invariant: refused leaves the field untouched; inserted gives exactly the spliced value.
    func testRandomFieldsEitherRefuseOrSpliceExactly() {
        var rng = InsertLCG(state: 0x29_1C5)
        let alphabet = Array("ab é\n")
        let textAlphabet = Array("xy z")
        var inserted = 0
        for _ in 0..<2_000 {
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
        XCTAssertTrue(text.contains("GhostInsertCheck.insert"))
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
}
