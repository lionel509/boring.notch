import XCTest
@testable import VoiceDictationLogic

/// Invariant (privacy): nothing the user said, whether audio or transcript text, reaches
/// the unified log. The only thing logged is `TakeReport.line`, made of numbers and enum codes.
final class LogPrivacyTests: XCTestCase {
    static let loggingSymbols = ["Logger(", "os_log", "NSLog", "print(", "debugPrint(", "dump(", "FileHandle"]

    /// (a) No report field can hold text.
    func testEveryReportFieldIsNumericBoolOrEnum() {
        for child in Mirror(reflecting: TakeReport()).children {
            let type = String(describing: Swift.type(of: child.value))
            XCTAssertFalse(type.contains("String"), "\(child.label ?? "?") is \(type)")
            XCTAssertFalse(type.contains("Substring"), "\(child.label ?? "?") is \(type)")
        }
    }

    /// (b) Only DictationLog.swift may log, and it logs exactly one thing: a TakeReport.
    func testOnlyDictationLogWritesToTheLog() throws {
        var sawLogFile = false
        for file in try voiceSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if file.lastPathComponent == "DictationLog.swift" {
                sawLogFile = true
                let funcLines = text.components(separatedBy: "\n").filter { $0.contains("func ") }
                XCTAssertEqual(funcLines.count, 1, "DictationLog.swift must have exactly one func")
                XCTAssertTrue(funcLines.first?.contains("TakeReport") == true, "the one func must take a TakeReport")
                continue
            }
            for symbol in Self.loggingSymbols {
                XCTAssertFalse(text.contains(symbol), "\(file.lastPathComponent) contains \(symbol)")
            }
        }
        XCTAssertTrue(sawLogFile, "DictationLog.swift not found")
    }

    /// (c) A populated report logs only key=value pairs with numbers, enum codes, or paths-like tokens.
    func testPopulatedLineMatchesTheNumbersOnlyShape() throws {
        let line = Self.sampleReport().line
        let regex = try NSRegularExpression(pattern: "^take( [a-z_]+=[A-Za-z0-9./-]+)+$")
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNotNil(regex.firstMatch(in: line, range: range), line)
    }

    func testLineHasTheExactFormat() {
        XCTAssertEqual(
            Self.sampleReport().line,
            "take outcome=pasted verdict=signal auth=3 granted=1 tap=1ch/48000Hz buf=1ch/48000Hz "
                + "buffers=100 chunks=25 peak=0.1000 max_db=-23.0 floor_db=-50.0 voiced=20 "
                + "config_changes=0 convert_failures=0 finals=2 partials=6 volatile_tail=0 "
                + "hold_ms=1200 finalize_ms=80 ax_ms=5 mod_wait_ms=0 paste_ms=12 release_to_paste_ms=150"
        )
    }

    func testMissingFloorPrintsNone() {
        var r = Self.sampleReport()
        r.floorDB = nil
        XCTAssertTrue(r.line.contains(" floor_db=none "), r.line)
    }

    private static func sampleReport() -> TakeReport {
        var r = TakeReport()
        r.outcome = .pasted
        r.authStatus = 3
        r.granted = true
        r.tapChannels = 1
        r.tapSampleRate = 48_000
        r.bufferChannels = 1
        r.bufferSampleRate = 48_000
        r.buffers = 100
        r.chunks = 25
        r.peak = 0.1
        r.maxDB = -23.0
        r.floorDB = -50.0
        r.voicedChunks = 20
        r.verdict = .signal
        r.configChanges = 0
        r.convertFailures = 0
        r.finals = 2
        r.partials = 6
        r.volatileTail = false
        r.holdMs = 1200
        r.finalizeMs = 80
        r.axMs = 5
        r.modWaitMs = 0
        r.pasteMs = 12
        r.releaseToPasteMs = 150
        return r
    }

    private func voiceSources() throws -> [URL] {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/LogPrivacyTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let voice = root.appendingPathComponent("boringNotch/Voice")
        let files = (FileManager.default.enumerator(at: voice, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { ["swift", "m", "h"].contains($0.pathExtension) }
        XCTAssertGreaterThanOrEqual(files.count, 5, "expected the voice sources, found \(files.count)")
        return files
    }
}
