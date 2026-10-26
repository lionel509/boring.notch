import XCTest
@testable import VoiceDictationLogic

private final class DemoField: GhostTextField {
    var value: String?
    var loc: Int
    init(_ v: String, _ l: Int) { value = v; loc = l }
    var selection: (location: Int, length: Int)? { (loc, 0) }
    func setSelectedText(_ t: String) -> Bool {
        let ns = (value ?? "") as NSString
        value = ns.replacingCharacters(in: NSRange(location: loc, length: 0), with: t)
        loc += (t as NSString).length
        return true
    }
    func string(location: Int, length: Int) -> String? {
        guard let v = value else { return nil }
        let ns = v as NSString
        guard location >= 0, length >= 0, location + length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: location, length: length))
    }
    var shown: String { let ns = (value ?? "") as NSString; return ns.substring(to: loc) + "|" + ns.substring(from: loc) }
}

/// Prints the demo tables to stdout (run: swift test --filter GhostTextDemoTests).
final class GhostTextDemoTests: XCTestCase {
    typealias L = GhostTextLogic
    private func key(_ flags: UInt64) -> L.KeyEvent {
        L.KeyEvent(keyCode: 48, flags: flags, isKeyDown: true, isAutorepeat: false, isSynthetic: false, characters: "\t")
    }

    func testPrintDemo() {
        let cases: [(String, String, Int, String, UInt64, Bool)] = [
            ("Option+Tab, overlay visible", "Hello |wor", 6, "ld", L.optionMask, true),
            ("Option+Tab, no overlay", "Hello wor", 9, "ld", L.optionMask, false),
            ("Tab, overlay visible", "Hello wor", 9, "ld", 0, true),
            ("Shift+Tab, overlay visible", "Hello wor", 9, "ld", L.shiftMask, true),
        ]
        for (name, raw, caret, sugg, flags, visible) in cases {
            let text = raw.replacingOccurrences(of: "|", with: "")
            let f = DemoField(text, min(caret, (text as NSString).length))
            let before = f.shown
            let d = L.decide(key(flags), suggestionVisible: visible)
            if d == .accept { _ = GhostInsertCheck.insert(sugg, at: f.loc, into: f) }
            print("DEMO | \(name) | before=\"\(before)\" | suggestion=\"\(sugg)\" | decision=\(d) | after=\"\(f.shown)\"")
        }
        for t in ["Hello wor", "Hello wor "] {
            print("DEMO | mid-word check | text=\"\(t)|\" | wordBoundary=\(GhostTextPolicy.wordBoundary(t))")
        }
        var m = L.Machine()
        _ = m.handle(.key(.typing))
        let g = m.gen
        print("DEMO | one pause, first fire effects=\(m.handle(.pauseFired(gen: g))) | second fire effects=\(m.handle(.pauseFired(gen: g)))")
        for (label, e) in [("accepted", GhostTextEvent.accepted), ("rejected", .dismissed), ("suppressed", .dropped)] {
            print("DEMO LOG | \(label) | \(GhostTextEvent.line(e, callsTotal: 3))")
        }
    }
}
