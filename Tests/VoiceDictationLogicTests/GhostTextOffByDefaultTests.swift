import XCTest

/// Structural checks on the app side: the feature is off by default, uses a defaultTap only,
/// and only allowlisted Voice files import FoundationModels.
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
        // Allowlist: GhostTextModel (ghost text) and TranscriptCleanup (#15, on-device dictation cleanup).
        // Any other Voice file importing FoundationModels fails this test.
        let allowed: Set<String> = ["GhostTextModel.swift", "TranscriptCleanup.swift"]
        XCTAssertEqual(Set(importers), allowed, "only the allowlisted Voice files may import FoundationModels")
        XCTAssertEqual(importers.count, allowed.count, "each allowlisted file should import FoundationModels exactly once")
    }
}
