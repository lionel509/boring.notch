import XCTest

final class BreakerRound2Tests: XCTestCase {
    private func repoFile(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    // dictationCloud defaults to true (Constants.swift). The mic prompt must not describe cloud as opt-in.
    func testMicPromptDoesNotCallCloudOptIn() throws {
        let constants = try repoFile("boringNotch/models/Constants.swift")
        XCTAssertTrue(constants.contains("Key<Bool>(\"dictationCloud\", default: true)"), "precondition: cloud default is on")
        let plist = try repoFile("boringNotch/Info.plist")
        XCTAssertFalse(plist.contains("If you turn on cloud dictation"),
                       "mic prompt says cloud is opt-in, but dictationCloud defaults to true")
    }
}
