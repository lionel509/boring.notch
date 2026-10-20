import XCTest

/// Invariant 1: audio and transcripts never leave the Mac. The voice code may
/// reach Speech.framework, NSPasteboard and the XPC helper, and nothing networked.
final class NoNetworkTests: XCTestCase {
    private let forbidden = ["URLSession", "NWConnection", "Network", "http://", "https://", "URLRequest"]

    func testNoNetworkingSymbolsUnderVoice() throws {
        for file in try voiceSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }

    /// The only fetch allowed is the OS one-time speech-model install, in
    /// SpeechAnalyzerSession.swift and nowhere else, with a single call site.
    func testModelDownloadIsTheOnlyAllowedFetch() throws {
        for file in try voiceSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "SpeechAnalyzerSession.swift" {
                let calls = text.components(separatedBy: "downloadAndInstall").count - 1
                XCTAssertEqual(calls, 1, "expected exactly one downloadAndInstall call, found \(calls)")
                XCTAssertTrue(text.contains("AssetInventory"))
            } else {
                XCTAssertFalse(text.contains("AssetInventory"), "\(file.lastPathComponent) contains AssetInventory")
                XCTAssertFalse(text.contains("downloadAndInstall"), "\(file.lastPathComponent) contains downloadAndInstall")
            }
        }
    }

    private func voiceSources() throws -> [URL] {
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
        return files
    }
}
