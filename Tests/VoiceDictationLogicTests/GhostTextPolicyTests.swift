import XCTest
@testable import VoiceDictationLogic

private struct GhostTextLCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class GhostTextPolicyTests: XCTestCase {
    private func safari(_ text: String? = "Hello wor") -> GhostTextSnapshot {
        var s = GhostTextSnapshot()
        s.bundleID = "com.apple.Safari"
        s.appName = "Safari"
        s.windowTitle = "GitHub"
        s.role = "AXTextArea"
        s.textBeforeCaret = text
        return s
    }

    func testSafariTextAreaIsAllowed() {
        XCTAssertTrue(GhostTextPolicy.allows(safari()))
    }

    func testSecureFieldsAreForbidden() {
        var s = safari()
        s.subrole = "AXSecureTextField"
        XCTAssertFalse(GhostTextPolicy.allows(s))
        s = safari()
        s.isSecure = true
        XCTAssertFalse(GhostTextPolicy.allows(s))
        s = safari()
        s.role = "AXSecureTextField"
        XCTAssertFalse(GhostTextPolicy.allows(s))
    }

    func testExcludedAppsAreForbidden() {
        for bundle in GhostTextPolicy.excludedBundleIDs {
            var s = safari()
            s.bundleID = bundle
            XCTAssertFalse(GhostTextPolicy.allows(s), bundle)
        }
        XCTAssertTrue(GhostTextPolicy.excludedBundleIDs.contains("md.obsidian"))
        XCTAssertTrue(GhostTextPolicy.excludedBundleIDs.contains("com.apple.Terminal"))
    }

    func testEmptyBundleNilTextAndShortTextAreForbidden() {
        var s = safari()
        s.bundleID = ""
        XCTAssertFalse(GhostTextPolicy.allows(s))
        XCTAssertFalse(GhostTextPolicy.allows(safari(nil)))
        XCTAssertFalse(GhostTextPolicy.allows(safari("hi")))
    }

    /// Generated invariant: forbidden inputs never reach the prompt, allowed ones always do.
    func testInvariantOverGeneratedSnapshots() {
        var rng = GhostTextLCG(state: 29)
        let bundles = Array(GhostTextPolicy.excludedBundleIDs) + ["com.apple.Safari", "com.apple.TextEdit", "com.hnc.Discord"]
        let subroles = ["", "AXSecureTextField", "AXSearchField"]
        let roles = ["AXTextArea", "AXTextField", "AXSecureTextField", "AXWebArea"]
        let texts: [String?] = [nil, "", "hi", "Hello world", String(repeating: "abcdefghij", count: 300)]
        var allowedRuns = 0
        var forbiddenRuns = 0
        for _ in 0..<10000 {
            var s = GhostTextSnapshot()
            s.bundleID = bundles.randomElement(using: &rng)!
            s.appName = "App\(Int.random(in: 0..<9, using: &rng))"
            s.windowTitle = "Window"
            s.subrole = subroles.randomElement(using: &rng)!
            s.role = roles.randomElement(using: &rng)!
            s.isSecure = Bool.random(using: &rng)
            s.textBeforeCaret = texts.randomElement(using: &rng)!
            let forbidden = s.isSecure || s.subrole == GhostTextPolicy.secureSubrole
                || s.role == "AXSecureTextField" || s.bundleID.isEmpty
                || GhostTextPolicy.excludedBundleIDs.contains(s.bundleID)
                || (s.textBeforeCaret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < GhostTextPolicy.minContextChars
            if forbidden {
                forbiddenRuns += 1
                XCTAssertFalse(GhostTextPolicy.allows(s))
                XCTAssertNil(GhostTextPrompt.build(s))
            } else {
                allowedRuns += 1
                XCTAssertTrue(GhostTextPolicy.allows(s))
                guard let prompt = GhostTextPrompt.build(s) else {
                    return XCTFail("allowed snapshot produced no prompt")
                }
                XCTAssertTrue(prompt.contains(s.appName))
                let text = s.textBeforeCaret ?? ""
                XCTAssertTrue(prompt.contains(String(text.suffix(GhostTextPolicy.maxContextChars))))
            }
        }
        // A green check must be able to go red: both branches have to be exercised.
        XCTAssertGreaterThanOrEqual(allowedRuns, 100)
        XCTAssertGreaterThanOrEqual(forbiddenRuns, 100)
    }
}
