import XCTest
@testable import VoiceDictationLogic

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class CallAppsTests: XCTestCase {
    typealias Apps = CallApps

    private func client(_ bundleID: String, pid: Int32 = 100, name: String? = nil) -> MicClient {
        MicClient(bundleID: bundleID, pid: pid, name: name)
    }

    func testNativeBundleIDsMapToCalls() {
        XCTAssertEqual(Apps.nativeCall(for: client("us.zoom.xos", pid: 7)),
                       DetectedCall(id: "zoom", name: "Zoom", pid: 7, viaBrowser: false))
        XCTAssertEqual(Apps.nativeCall(for: client("com.hnc.Discord.helper"))?.id, "discord")
        XCTAssertEqual(Apps.nativeCall(for: client("com.hnc.DiscordPTB"))?.id, "discord")
        XCTAssertEqual(Apps.nativeCall(for: client("com.microsoft.teams2"))?.id, "teams")
    }

    func testLookalikeBundleIDsAreNotCalls() {
        XCTAssertNil(Apps.nativeCall(for: client("com.microsoft.teamsX")))
        XCTAssertNil(Apps.nativeCall(for: client("com.apple.corespeechd")))
    }

    func testBrowsersAreBrowsersNotNativeCalls() {
        XCTAssertTrue(Apps.isBrowser("com.google.Chrome.helper"))
        XCTAssertNil(Apps.nativeCall(for: client("com.google.Chrome.helper")))
        XCTAssertTrue(Apps.isBrowser("com.apple.WebKit.GPU"))
        XCTAssertTrue(Apps.isBrowser("com.apple.Safari.WebApp.ABC"))
        XCTAssertFalse(Apps.isBrowser("com.apple.corespeechd"))
    }

    func testBrowserTitleMatchesMeet() {
        let call = Apps.browserCall(titles: ["Inbox - Gmail", "Meet - abc-defg-hij"], pid: 42)
        XCTAssertEqual(call, DetectedCall(id: "meet", name: "Google Meet", pid: 42, viaBrowser: true))
    }

    func testBrowserTitleMatchesJitsi() {
        XCTAssertEqual(Apps.browserCall(titles: ["standup | Jitsi Meet"], pid: 1)?.id, "jitsi")
    }

    func testBrowserTitleWithoutServiceIsNotACall() {
        XCTAssertNil(Apps.browserCall(titles: ["zoom lens review"], pid: 1))
        XCTAssertNil(Apps.browserCall(titles: [], pid: 1))
    }

    func testDisplayNameFallsBackToID() {
        XCTAssertEqual(Apps.displayName(for: "zoom"), "Zoom")
        XCTAssertEqual(Apps.displayName(for: "mystery"), "mystery")
    }

    func testIndicatorNameIsTheFirstNamedClient() {
        let clients = [client("a.unnamed", name: nil), client("us.zoom.xos", name: "Zoom"), client("b", name: "Discord")]
        XCTAssertEqual(Apps.indicatorName(clients), "Zoom")
        XCTAssertNil(Apps.indicatorName([client("a.unnamed", name: nil)]))
        XCTAssertNil(Apps.indicatorName([]))
    }

    /// A browser call never carries window-title text: the result's name and id come from the fixed table only.
    func testBrowserCallNeverCarriesTitleText() {
        var rng = SplitMix64(state: 0x22_00A5)
        let alnum = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let filler = Array("abcdefgh ijk-lmn|opq")
        let keywords = Apps.services.flatMap { $0.contains } + ["Meet - "]
        let tableNames = Set(Apps.services.map { $0.name })
        let tableIDs = Set(Apps.services.map { $0.id })

        for _ in 0..<2000 {
            let token = String((0..<12).map { _ in alnum.randomElement(using: &rng)! })
            let keyword = Bool.random(using: &rng) ? keywords.randomElement(using: &rng)! : ""
            let pad = String((0..<Int.random(in: 0...10, using: &rng)).map { _ in filler.randomElement(using: &rng)! })
            let title = Bool.random(using: &rng) ? pad + keyword + token : pad + token + keyword + pad

            guard let call = Apps.browserCall(titles: [title], pid: 5) else { continue }
            XCTAssertTrue(tableNames.contains(call.name), "name not from the table: \(call.name)")
            XCTAssertTrue(tableIDs.contains(call.id), "id not from the table: \(call.id)")
            XCTAssertFalse(call.name.contains(token))
            XCTAssertFalse(call.id.contains(token))
        }
    }
}
