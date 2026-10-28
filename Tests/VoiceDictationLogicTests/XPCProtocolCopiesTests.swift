import XCTest

/// The XPC protocol is compiled into both the app and the helper; the two copies must match byte for byte.
final class XPCProtocolCopiesTests: XCTestCase {
    private func read(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testProtocolCopiesAreIdentical() throws {
        let helper = try read("BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift")
        let app = try read("boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift")
        XCTAssertEqual(helper, app)
    }

    func testProtocolDeclaresFocusedTextSnapshot() throws {
        let helper = try read("BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift")
        XCTAssertTrue(helper.contains("focusedTextSnapshot(with reply"))
    }

    /// #47 finding 5: the insert takes the one-use token, and Option+Tab can be posted back by the helper.
    func testProtocolHasTokenInsertAndPassThrough() throws {
        let helper = try read("BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift")
        XCTAssertTrue(helper.contains("func ghostInsert(_ token: String, _ location: Int, _ text: String"))
        XCTAssertTrue(helper.contains("func postGhostAcceptKey(with reply"))
    }
}
