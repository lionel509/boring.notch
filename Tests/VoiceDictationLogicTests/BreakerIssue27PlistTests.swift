import XCTest

final class BreakerIssue27PlistTests: XCTestCase {
    func testMicPermissionTextDoesNotPointAtRemovedShortcut() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = try String(contentsOf: root.appendingPathComponent("boringNotch/Info.plist"), encoding: .utf8)
        XCTAssertFalse(plist.contains("Hold the dictation shortcut"),
                       "NSMicrophoneUsageDescription still says 'Hold the dictation shortcut' ...")
        XCTAssertFalse(plist.contains("never leaves the machine"),
                       "NSMicrophoneUsageDescription says audio never leaves the machine, which is false with cloud on")
        XCTAssertTrue(plist.contains("Hold fn"),
                      "NSMicrophoneUsageDescription should tell the user to hold fn")
    }
}
