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
    }
}
