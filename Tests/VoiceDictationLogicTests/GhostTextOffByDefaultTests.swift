import XCTest

/// Structural checks on the app side: the feature is off by default, uses a defaultTap only,
/// and only one file imports FoundationModels.
final class GhostTextOffByDefaultTests: XCTestCase {
    private func root() -> URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relative), encoding: .utf8)
    }

    func testGhostTextDefaultsOff() throws {
        let constants = try read("boringNotch/models/Constants.swift")
        XCTAssertTrue(constants.contains(#"Key<Bool>("ghostText", default: false)"#))
    }

    func testManagerUsesDefaultTapOnly() throws {
        let manager = try read("boringNotch/Voice/Ghost/GhostTextManager.swift")
        XCTAssertTrue(manager.contains(".defaultTap"))
        XCTAssertFalse(manager.contains(".listenOnly"))
    }

    func testOnlyModelFileImportsFoundationModels() throws {
        let voice = root().appendingPathComponent("boringNotch/Voice")
        let files = FileManager.default.enumerator(at: voice, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let importers = try files.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("import FoundationModels")
        }.map { $0.lastPathComponent }
        XCTAssertEqual(importers, ["GhostTextModel.swift"])
    }
}
