import XCTest

/// Issue #27 part 1: fn is the only dictation trigger. The Option-Space `.dictate`
/// shortcut, its listener, and the hotkeyDown/hotkeyUp entry points are gone from app code.
final class FnOnlyTriggerTests: XCTestCase {
    static let forbidden = ["Self(\"dictate\"", "events(for: .dictate)", "name: .dictate", "hotkeyDown", "hotkeyUp", "Option-Space", "⌥Space"]

    func testNoOptionSpaceDictateShortcutInAppCode() throws {
        for file in try appSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbidden {
                XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }

    private func appSources() throws -> [URL] {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/FnOnlyTriggerTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = root.appendingPathComponent("boringNotch")
        let files = (FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Swift sources found under \(app.path)")
        return files
    }
}
