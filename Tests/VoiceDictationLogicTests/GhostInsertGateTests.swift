import XCTest
@testable import VoiceDictationLogic

/// #47 finding 5: ghost text is written only into the element the read found, through a one-use token.
final class GhostInsertGateTests: XCTestCase {
    typealias G = GhostInsertGate

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

    private func refusal(age: TimeInterval? = 0.1, front: Bool = true, focused: Bool = true,
                         role: String? = "AXTextArea", subrole: String? = "") -> G.Refusal? {
        G.refusal(age: age, pidFrontmost: front, focusUnchanged: focused, role: role, subrole: subrole)
    }

    // MARK: - Copies

    func testGateCopiesAreByteIdentical() throws {
        let app = try read("boringNotch/Voice/Logic/GhostInsertGate.swift")
        let helper = try read("BoringNotchXPCHelper/GhostInsertGate.swift")
        XCTAssertEqual(app, helper)
    }

    // MARK: - Helper-side refusal

    func testAllGuardsPassWithAFreshTokenInAPlainField() {
        XCTAssertNil(refusal())
    }

    func testEachGuardAloneRefuses() {
        XCTAssertEqual(refusal(age: nil), G.Refusal.staleToken)
        XCTAssertEqual(refusal(age: -0.01), G.Refusal.staleToken)
        XCTAssertEqual(refusal(age: 2.001), G.Refusal.staleToken)
        XCTAssertNil(refusal(age: 2.0), "a token exactly 2 s old is still good")
        XCTAssertEqual(refusal(front: false), G.Refusal.notFrontmost)
        XCTAssertEqual(refusal(focused: false), G.Refusal.focusMoved)
        XCTAssertEqual(refusal(role: "AXSecureTextField", subrole: ""), G.Refusal.secure)
        XCTAssertEqual(refusal(role: "AXTextField", subrole: "AXSecureTextField"), G.Refusal.secure)
        XCTAssertEqual(refusal(role: nil, subrole: ""), G.Refusal.secure, "an unreadable role fails closed")
    }

    /// I1, exhaustive: the write is allowed exactly when every guard holds.
    func testWriteOnlyWhenEveryGuardHolds() {
        let ages: [TimeInterval?] = [nil, -0.1, 0, 1, 2, 2.0001, 60]
        let roles: [String?] = [nil, "AXTextField", "AXTextArea", "AXComboBox", "AXWebArea", "AXSecureTextField"]
        let subroles: [String?] = [nil, "", "AXSearchField", "AXSecureTextField"]
        for age in ages {
            for front in [true, false] {
                for focused in [true, false] {
                    for role in roles {
                        for subrole in subroles {
                            let fresh = age.map { $0 >= 0 && $0 <= 2 } ?? false
                            // #31 round 7: the allow-list, exact match. Anything else is refused.
                            let allowedRole = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "")
                            let allowedSubrole = subrole == nil || subrole == "" || subrole == "AXSearchField"
                            let expected = fresh && front && focused && allowedRole && allowedSubrole
                            let got = refusal(age: age, front: front, focused: focused, role: role, subrole: subrole)
                            XCTAssertEqual(got == nil, expected,
                                           "age \(String(describing: age)) front \(front) focused \(focused) role \(String(describing: role)) subrole \(String(describing: subrole))")
                        }
                    }
                }
            }
        }
    }

    func testRefusalCodesDoNotCollide() {
        XCTAssertEqual(G.Refusal.allCases.map(\.rawValue), [8, 9, 10, 11])
        let taken = Set([GhostInsertCheck.Result.inserted, .setFailed, .unverified, .refused].map(\.rawValue))
        let existing: Set<Int> = [-1, 0, 2, 3, 4, 5, 6, 7]
        for code in G.Refusal.allCases.map(\.rawValue) {
            XCTAssertFalse(existing.contains(code), "\(code) is already a reply code")
            XCTAssertFalse(taken.contains(code), "\(code) is already a GhostInsertCheck code")
        }
    }

    // MARK: - Pass-through

    /// I3, exhaustive: Option+Tab comes back only when nothing can have been written and the app is still frontmost.
    func testPassThroughOnlyWhenNothingWasWritten() {
        let results: [Int?] = [nil, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 99]
        let keyApps: [String?] = [nil, "", "com.google.Chrome"]
        let fronts: [String?] = [nil, "com.google.Chrome", "com.apple.Safari"]
        let nothingWritten: Set<Int> = [4, 5, 6, 8, 9, 10, 11]
        for result in results {
            for keyApp in keyApps {
                for front in fronts {
                    let sameApp = keyApp == "com.google.Chrome" && front == "com.google.Chrome"
                    let expected = sameApp && (result == nil || nothingWritten.contains(result!))
                    XCTAssertEqual(G.passThrough(result: result, keyApp: keyApp, frontNow: front), expected,
                                   "result \(String(describing: result)) keyApp \(String(describing: keyApp)) front \(String(describing: front))")
                }
            }
        }
    }

    func testPassThroughNeverFollowsAWriteOrAnUnknownOutcome() {
        for result in [0, 2, 3, 7, -1] {
            XCTAssertFalse(G.passThrough(result: result, keyApp: "com.google.Chrome", frontNow: "com.google.Chrome"),
                           "result \(result) may have written")
        }
    }

    // MARK: - App-side gate

    func testAppAllowsNeedsATokenAndANonSecureField() {
        for token in [nil, "", "t"] as [String?] {
            for secure in [true, false] {
                for (role, subrole) in [("AXTextField", ""), ("AXSecureTextField", ""), ("AXTextField", "AXSecureTextField")] {
                    let expected = token == "t" && !secure && role != "AXSecureTextField" && subrole != "AXSecureTextField"
                    XCTAssertEqual(G.appAllows(token: token, isSecure: secure, role: role, subrole: subrole), expected,
                                   "token \(String(describing: token)) secure \(secure) role \(role) subrole \(subrole)")
                }
            }
        }
    }

    /// Finding 5: fetch and insert must agree for direct and frontmost-fallback reads alike.
    func testFetchAndInsertAgreeForDirectAndFallbackReads() {
        func json(fallback: Bool, token: Bool) -> String {
            var s = #"{"bundleID":"com.google.Chrome","appName":"Chrome","role":"AXTextArea","textBeforeCaret":"hello wor","caretLocation":9,"caretAtEnd":true,"caretX":10,"caretY":10,"caretWidth":1,"caretHeight":14,"fieldX":0,"fieldY":0,"fieldWidth":400,"fieldHeight":30"#
            if fallback { s += #","focusVia":"frontmost","axError":-25212"# }
            if token { s += #","token":"t""# }
            return s + "}"
        }
        for fallback in [true, false] {
            for token in [true, false] {
                let raw = json(fallback: fallback, token: token)
                guard case .snapshot(let snap, _, _) = GhostSnapshotRead.classify(.some(raw), frontmostBundleID: "com.google.Chrome") else {
                    XCTFail("read should classify as a snapshot: \(raw)")
                    continue
                }
                XCTAssertEqual(G.appAllows(token: snap.token, isSecure: snap.isSecure, role: snap.role, subrole: snap.subrole),
                               token, "fallback \(fallback) token \(token)")
            }
        }
    }

    func testSnapshotDecodesToken() {
        XCTAssertEqual(GhostTextSnapshot.decode(#"{"token":"abc"}"#)?.token, "abc")
        XCTAssertNil(GhostTextSnapshot.decode("{}")?.token)
    }

    // MARK: - Token slot

    func testTokenSlot() {
        var slot = GhostTokenSlot<Int>()
        let t = slot.put(7, now: 10)
        let hit = slot.take(t, now: 10.5)
        XCTAssertEqual(hit?.value, 7)
        XCTAssertEqual(hit?.age, 0.5)
        XCTAssertNil(slot.take(t, now: 10.6), "a token is good for one use")

        var replaced = GhostTokenSlot<Int>()
        let a = replaced.put(1, now: 0)
        _ = replaced.put(2, now: 0)
        XCTAssertNil(replaced.take(a, now: 0), "a newer read replaces the older token")

        var restarted = GhostTokenSlot<Int>()
        XCTAssertNil(restarted.take("x", now: 0), "a fresh slot (helper restart) knows no token")

        var empty = GhostTokenSlot<Int>()
        _ = empty.put(3, now: 0, token: "")
        XCTAssertNil(empty.take("", now: 0))

        var cleared = GhostTokenSlot<Int>()
        let c = cleared.put(1, now: 0)
        cleared.clear()
        XCTAssertNil(cleared.take(c, now: 0))

        var fresh = GhostTokenSlot<Int>()
        XCTAssertNotEqual(fresh.put(1, now: 0), fresh.put(1, now: 0))
    }

    // MARK: - Source pins

    /// I1: ghostInsert writes only through the stored element, never through the system-wide focus.
    func testHelperInsertWritesOnlyThroughTheGate() throws {
        let text = try read("BoringNotchXPCHelper/BoringNotchXPCHelper.swift")
        let body = section(text, from: "func ghostInsert(", to: "private struct AXGhostField")
        XCTAssertTrue(body.contains("FocusedTextReader.takeToken("))
        XCTAssertTrue(body.contains("GhostInsertGate.refusal("))
        XCTAssertFalse(body.contains("currentFocusedElement"), "ghostInsert must not read the focus")
        XCTAssertFalse(body.contains("AXUIElementCreateSystemWide"), "ghostInsert must not read the system-wide focus")
        let gate = body.range(of: "GhostInsertGate.refusal(")?.lowerBound
        let write = body.range(of: "GhostInsertCheck.accept(")?.lowerBound
        XCTAssertNotNil(gate)
        XCTAssertNotNil(write)
        if let gate, let write { XCTAssertLessThan(gate, write, "the gate must come before any write") }
        let beforeTyping = body.components(separatedBy: "typeUnicode(typed, pid: taken.pid)").first ?? ""
        XCTAssertGreaterThanOrEqual(count(beforeTyping, "ghostTargetFocused("), 2,
                                    "typed fallback must re-check the focus right before typing")
        // Finding 3: the focus re-check must refuse before typing. Deleting this guard must turn the test red.
        let recheck = "guard now.frontmost, now.focused else { return false }"
        let lastCheck = beforeTyping.range(of: "ghostTargetFocused(", options: .backwards)?.lowerBound
        let guardAt = beforeTyping.range(of: recheck)?.lowerBound
        XCTAssertNotNil(guardAt, "the typed fallback must refuse when the focus moved")
        if let lastCheck, let guardAt {
            XCTAssertLessThan(lastCheck, guardAt, "the refusal must follow the focus re-check")
        }
    }

    /// I1: a token is issued only for a non-secure field with a caret, and every read clears the old one.
    func testReaderIssuesTokenOnlyForANonSecureCaret() throws {
        let text = try read("BoringNotchXPCHelper/FocusedTextReader.swift")
        XCTAssertEqual(count(text, "issueToken("), 2, "one definition and one call")
        let snapshot = section(text, from: "static func snapshotJSON(", to: "private static func failure(")
        XCTAssertTrue(snapshot.contains("clearToken()"))
        // XCTUnwrap, not `!`: a missing marker must fail this one test, not crash the whole xctest run (finding 4).
        let clear = try XCTUnwrap(snapshot.range(of: "clearToken()")).lowerBound
        XCTAssertLessThan(clear, try XCTUnwrap(snapshot.range(of: "AXIsProcessTrusted()")).lowerBound)
        guard let call = snapshot.range(of: "issueToken(pid: pid, element: focused)") else {
            return XCTFail("snapshotJSON must issue the token from the focused element")
        }
        XCTAssertGreaterThan(call.lowerBound, try XCTUnwrap(snapshot.range(of: "if isSecure {")).lowerBound)
        XCTAssertGreaterThan(call.lowerBound, try XCTUnwrap(snapshot.range(of: "selection.length == 0")).lowerBound)
    }

    /// Only the app's XPC client and the one accept in GhostTextManager may call ghostInsert.
    func testGhostInsertHasExactlyOneCaller() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appRoot = root.appendingPathComponent("boringNotch")
        let enumerator = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil)
        var callers: [String: Int] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = count(text, ".ghostInsert(")
            if n > 0 { callers[url.path.replacingOccurrences(of: root.path + "/", with: "")] = n }
        }
        XCTAssertEqual(callers, [
            "boringNotch/XPCHelperClient/XPCHelperClient.swift": 1,
            "boringNotch/Voice/Ghost/GhostTextManager.swift": 1,
        ])
    }
}
