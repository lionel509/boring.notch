import Carbon
import XCTest
@testable import VoiceDictationLogic

final class PasteKeycodeTests: XCTestCase {
    private func layoutData(_ id: String) throws -> Data {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first
        else { throw XCTSkip("layout \(id) is not installed") }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw XCTSkip("layout \(id) has no unicode key data")
        }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    func testUSLayoutPastesWithKeycodeZeroNineV() throws {
        XCTAssertEqual(PasteKeycode.keyCode(typing: "v", layoutData: try layoutData("com.apple.keylayout.US")), 0x09)
    }

    /// Breaker U2-B1: a hard-coded 0x09 types "k" under Dvorak and the transcript is lost.
    func testDvorakLayoutDoesNotUseTheQWERTYPosition() throws {
        let code = PasteKeycode.keyCode(typing: "v", layoutData: try layoutData("com.apple.keylayout.Dvorak"))
        XCTAssertNotNil(code)
        XCTAssertNotEqual(code, 0x09)
    }

    func testDvorakQwertyCommandLayoutPastesWithPhysicalV() throws {
        XCTAssertEqual(
            PasteKeycode.keyCode(typing: "v", layoutData: try layoutData("com.apple.keylayout.DVORAK-QWERTYCMD")),
            0x09)
    }
}
