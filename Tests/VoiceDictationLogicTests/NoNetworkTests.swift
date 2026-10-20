import XCTest

/// Invariant 1: audio and transcripts never leave the Mac. The voice code may
/// reach Speech.framework, NSPasteboard and the XPC helper, and nothing networked.
final class NoNetworkTests: XCTestCase {
    private let forbidden = ["URLSession", "NWConnection", "Network", "http://", "https://", "URLRequest"]

    func testNoNetworkingSymbolsUnderVoice() throws {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/NoNetworkTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let voice = root.appendingPathComponent("boringNotch/Voice")

        let files = (FileManager.default.enumerator(at: voice, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 5, "expected the voice sources, found \(files.count)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }
}
