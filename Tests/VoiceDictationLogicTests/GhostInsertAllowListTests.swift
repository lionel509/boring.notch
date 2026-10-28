import XCTest
@testable import VoiceDictationLogic

/// #31 round 7 decision: ghost text is inserted only into an exact allow-list of AX roles and subroles.
/// Anything else, padded, invisible-character, unknown or unreadable, is refused and logged.
final class GhostInsertAllowListTests: XCTestCase {
    typealias G = GhostInsertGate

    private let allowedRoles = ["AXTextField", "AXTextArea", "AXComboBox"]
    private let allowedSubroles: [String?] = [nil, "", "AXSearchField"]

    private func hex(_ s: String) -> String {
        s.unicodeScalars.map { String(format: "%04x", $0.value) }.joined(separator: " ")
    }

    private func read(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - Round-7 breaks

    /// Round-7 break 1: a role made only of U+FEFF or U+2060 (format characters) was read as a plain field.
    func testR7_1InvisibleFormatCharRoleIsRefused() {
        for role in ["\u{200B}", "\u{FEFF}", "\u{2060}", "\u{200B}\u{200B}", " \u{200B} ", "\u{FEFF}AXTextArea"] {
            XCTAssertTrue(G.isSecure(role: role, subrole: ""), "invisible-char role [\(hex(role))] read as plain")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: role, subrole: ""),
                           "app gate allows invisible-char role [\(hex(role))]")
            XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: role, subrole: ""), .secure,
                           "helper allows invisible-char role [\(hex(role))]")
        }
    }

    /// Round-7 break 2: a padded AXSecureTextField role or subrole was not matched by the exact `==` secure check.
    func testR7_2PaddedSecureRoleIsRefused() {
        for role in [" AXSecureTextField ", "\tAXSecureTextField\n", "\u{00A0}AXSecureTextField", "AXSecureTextField "] {
            XCTAssertTrue(G.isSecure(role: role, subrole: ""), "padded secure role \(role.debugDescription) read as plain")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: role, subrole: ""),
                           "app gate allows padded secure role \(role.debugDescription)")
            XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: role, subrole: ""), .secure)
        }
    }

    func testR7_2PaddedSecureSubroleIsRefused() {
        for subrole in [" AXSecureTextField ", "\tAXSecureTextField\n", "AXSecureTextField "] {
            XCTAssertTrue(G.isSecure(role: "AXTextField", subrole: subrole), "padded secure subrole \(subrole.debugDescription) read as plain")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: "AXTextField", subrole: subrole))
            XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: "AXTextField", subrole: subrole), .secure)
        }
    }

    /// Round-7 break 2 through the wire: the snapshot the helper sends with a padded secure role must not fetch or insert.
    func testR7_2WirePaddedSecureRoleCannotFetchOrInsert() throws {
        let raw = #"{"bundleID":"com.google.Chrome","appName":"Chrome","role":" AXSecureTextField ","subrole":"","isSecure":false,"token":"t1","textBeforeCaret":"Password: ","caretLocation":10,"caretAtEnd":true}"#
        let snap = try XCTUnwrap(GhostTextSnapshot.decode(raw))
        XCTAssertFalse(G.appAllows(token: snap.token, isSecure: snap.isSecure, role: snap.role, subrole: snap.subrole))
    }

    // MARK: - Allow-list

    func testEachAllowedRoleIsAcceptedWithEachAllowedSubrole() {
        for role in allowedRoles {
            for subrole in allowedSubroles {
                XCTAssertFalse(G.isSecure(role: role, subrole: subrole ?? ""), "\(role) subrole \(String(describing: subrole))")
                XCTAssertTrue(G.appAllows(token: "t1", isSecure: false, role: role, subrole: subrole ?? ""),
                              "\(role) subrole \(String(describing: subrole)) refused by the app gate")
                XCTAssertNil(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: role, subrole: subrole),
                             "\(role) subrole \(String(describing: subrole)) refused by the helper")
            }
        }
    }

    func testAXSecureTextFieldAsSubroleIsRefusedForEveryAllowedRole() {
        for role in allowedRoles {
            XCTAssertTrue(G.isSecure(role: role, subrole: "AXSecureTextField"), role)
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: role, subrole: "AXSecureTextField"), role)
            XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: role, subrole: "AXSecureTextField"), .secure)
        }
    }

    func testPaddedAllowedRoleIsRefused() {
        for role in [" AXTextArea ", "AXTextArea\n", "AXTextArea\u{00A0}", "\tAXComboBox", "AXTextField\u{FEFF}"] {
            XCTAssertTrue(G.isSecure(role: role, subrole: ""), "padded role \(role.debugDescription) read as allowed")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: role, subrole: ""), role.debugDescription)
        }
    }

    func testRoleIsCaseSensitive() {
        for role in ["axtextarea", "AXTEXTAREA", "Axtextfield", "axcombobox"] {
            XCTAssertTrue(G.isSecure(role: role, subrole: ""), "\(role) folded to an allowed role")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: role, subrole: ""), role)
        }
    }

    func testUnknownRolesAreRefused() {
        for role in ["AXWebArea", "AXGroup", "AXStaticText", "AXButton", "AXSecureTextFieldX", "AXTextFieldX", ""] {
            XCTAssertTrue(G.isSecure(role: role, subrole: ""), "\(role.debugDescription) read as allowed")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: role, subrole: ""), role.debugDescription)
            XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: role, subrole: ""), .secure)
        }
    }

    /// A contenteditable that Chromium reports as AXWebArea is refused on purpose; the log shows the raw role.
    func testAXWebAreaIsRefused() {
        XCTAssertTrue(G.isSecure(role: "AXWebArea", subrole: ""))
        XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: "AXWebArea", subrole: ""))
        XCTAssertEqual(G.refusal(age: 0.1, pidFrontmost: true, focusUnchanged: true, role: "AXWebArea", subrole: ""), .secure)
    }

    func testUnknownSubrolesAreRefused() {
        for subrole in [" AXSearchField", "AXSearchField ", "AXSearchFieldX", "axsearchfield", "AXSearchField\u{200B}", "AXFoo"] {
            XCTAssertTrue(G.isSecure(role: "AXTextField", subrole: subrole), "subrole \(subrole.debugDescription) read as allowed")
            XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: "AXTextField", subrole: subrole), subrole.debugDescription)
        }
    }

    func testMissingRoleFailsClosed() {
        XCTAssertTrue(G.isSecure(role: nil, subrole: nil))
        XCTAssertFalse(G.appAllows(token: "t1", isSecure: false, role: "", subrole: ""))
    }

    // MARK: - Logging

    /// The refusal reasons exist in both the gate and the manager's log lines, with the raw value handed to the log.
    func testRefusalReasonsAreLogged() throws {
        let gate = try read("boringNotch/Voice/Logic/GhostInsertGate.swift")
        XCTAssertTrue(gate.contains("roleNotAllowed"), "the gate must name the role refusal")
        XCTAssertTrue(gate.contains("subroleNotAllowed"), "the gate must name the subrole refusal")
        let manager = try read("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertTrue(manager.contains("GhostInsertGate.refusedBy("), "the manager must log the refusal reason")
    }

    func testRefusedValueIsEscapedInTheLogLine() {
        XCTAssertEqual(GhostTextEvent.escaped("AXTextArea"), "\"AXTextArea\"")
        XCTAssertEqual(GhostTextEvent.escaped(" AXTextArea "), "\"\\u{20}AXTextArea\\u{20}\"")
        XCTAssertEqual(GhostTextEvent.escaped("a\"b\\c"), "\"a\\u{22}b\\u{5c}c\"")
        XCTAssertEqual(GhostTextEvent.escaped("\u{FEFF}"), "\"\\u{feff}\"")
        XCTAssertEqual(GhostTextEvent.escaped(""), "\"\"")
        XCTAssertEqual(GhostTextEvent.escaped(String(repeating: "x", count: 100)).count, 66, "at most 64 scalars")
        let line = GhostTextEvent.line(.dropped, callsTotal: 0, reason: .roleNotAllowed, app: "com.google.Chrome", value: "\u{FEFF}")
        XCTAssertEqual(line, "ghost event=dropped calls=0 reason=roleNotAllowed app=com.google.Chrome value=\"\\u{feff}\"")
    }

    func testRefusedFieldsMapToTheirLogReason() {
        XCTAssertEqual(GhostTextEvent.reason(.roleNotAllowed), .roleNotAllowed)
        XCTAssertEqual(GhostTextEvent.reason(.subroleNotAllowed), .subroleNotAllowed)
        XCTAssertEqual(G.refusedBy(role: "AXWebArea", subrole: "")?.value, "AXWebArea")
        XCTAssertEqual(G.refusedBy(role: "AXTextField", subrole: "AXFoo")?.reason, .subroleNotAllowed)
        XCTAssertNil(G.refusedBy(role: "AXTextField", subrole: nil))
    }
}
