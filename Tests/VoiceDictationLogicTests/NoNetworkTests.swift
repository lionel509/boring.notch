import XCTest

/// Invariant 1: audio and transcripts never leave the Mac. The voice code may
/// reach Speech.framework, NSPasteboard and the XPC helper, and nothing networked.
final class NoNetworkTests: XCTestCase {
    static let forbidden = ["URLSession", "NWConnection", "Network", "URLRequest", "://", "NSURL", "CFHTTP", "SFSpeech", "URL(string", "Data(contentsOf", "String(contentsOf", "socket("]
    static let scannedExtensions: Set<String> = ["swift", "m", "mm", "h", "c", "cpp"]

    func testNoNetworkingSymbolsUnderVoice() throws {
        for file in try voiceSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(Self.violations(in: text), [], file.lastPathComponent)
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

    /// Each probe is a cloud-call route the old token list missed (breaker B3 to B9).
    func testScannerFlagsKnownCloudRoutes() {
        let probes = [
            "import Foundation\nfunc p() { _ = NSURLConnection.self }\n",
            "import Foundation\nlet m = CFHTTPMessageCreateRequest(nil, \"GET\" as CFString, nil, kCFHTTPVersion1_1)\n",
            "import Speech\nlet r = SFSpeechRecognizer()\nlet q = SFSpeechURLRecognitionRequest(url: u)\nq.requiresOnDeviceRecognition = false\n",
            "import Darwin\nlet fd = socket(AF_INET, SOCK_STREAM, 0)\n",
            "let base = \"ht\" + \"tps://api.example.invalid/v1\"\n",
            "import Foundation\nlet d = try? Data(contentsOf: URL(string: remoteString)!)\n",
            "#import <Foundation/Foundation.h>\n@interface P : NSObject @end\n[NSURLSession sharedSession];\n",
        ]
        for probe in probes {
            XCTAssertFalse(Self.violations(in: probe).isEmpty, probe)
        }
        XCTAssertEqual(Self.violations(in: "let x = 1\n"), [])
    }

    /// Objective-C and header sources under Voice are scanned too, not only .swift.
    func testScannerReadsNonSwiftSources() {
        XCTAssertTrue(Self.isScanned(URL(fileURLWithPath: "/x/P.swift")))
        XCTAssertTrue(Self.isScanned(URL(fileURLWithPath: "/x/P.m")))
        XCTAssertTrue(Self.isScanned(URL(fileURLWithPath: "/x/P.mm")))
        XCTAssertTrue(Self.isScanned(URL(fileURLWithPath: "/x/P.h")))
        XCTAssertFalse(Self.isScanned(URL(fileURLWithPath: "/x/README.md")))
    }

    /// v2-6 (amended by v4): the OpenRouter host lives in exactly one file, the cloud client. URLSession
    /// and URLRequest stay out of the voice and cloud folders except in that file.
    func testOpenRouterHostLivesInOneFile() throws {
        let root = Self.repoRoot()
        let client = "boringNotch/Cloud/OpenRouterClient.swift"
        var hosting: [String] = []
        for dir in ["boringNotch", "BoringNotchXPCHelper"] {
            guard let walk = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else {
                XCTFail("cannot walk \(dir)")
                continue
            }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("openrouter.ai") {
                    hosting.append(String(url.path.dropFirst(root.path.count + 1)))
                }
            }
        }
        XCTAssertEqual(hosting.sorted(), [client])

        let text = try String(contentsOf: root.appendingPathComponent(client), encoding: .utf8)
        for literal in text.components(separatedBy: "\"https://").dropFirst() {
            XCTAssertTrue(literal.hasPrefix("openrouter.ai/"), "\(client) reaches \(literal.prefix(40))")
        }

        for dir in ["boringNotch/Voice", "boringNotch/Cloud"] {
            for file in Self.swiftFiles(under: root.appendingPathComponent(dir)) where !file.hasSuffix("/" + client) {
                let source = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
                XCTAssertFalse(source.contains("URLSession"), file)
                XCTAssertFalse(source.contains("URLRequest"), file)
            }
        }
    }

    private static func repoRoot() -> URL {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/NoNetworkTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under dir: URL) -> [String] {
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix(".swift") }
    }

    static func violations(in text: String) -> [String] {
        forbidden.filter { text.contains($0) }
    }

    static func isScanned(_ url: URL) -> Bool {
        scannedExtensions.contains(url.pathExtension)
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
            .filter { Self.isScanned($0) }
        XCTAssertGreaterThanOrEqual(files.count, 5, "expected the voice sources, found \(files.count)")
        return files
    }
}
