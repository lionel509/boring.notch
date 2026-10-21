import XCTest
@testable import VoiceDictationLogic

/// Scope 4 (backend): the tone follows the frontmost app's bundle id.
final class AppToneTests: XCTestCase {
    func testChatApps() {
        for id in [
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS",
            "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp",
        ] {
            XCTAssertEqual(AppTone.forBundle(id), .chat, id)
        }
    }

    func testEmailApps() {
        XCTAssertEqual(AppTone.forBundle("com.apple.mail"), .email)
        XCTAssertEqual(AppTone.forBundle("com.microsoft.Outlook"), .email)
    }

    func testCodeApps() {
        for id in [
            "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
            "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        ] {
            XCTAssertEqual(AppTone.forBundle(id), .code, id)
        }
    }

    func testNotesApps() {
        for id in ["md.obsidian", "com.apple.Notes", "com.apple.TextEdit", "com.apple.iWork.Pages"] {
            XCTAssertEqual(AppTone.forBundle(id), .notes, id)
        }
    }

    func testUnknownAndMissingBundlesAreNeutral() {
        XCTAssertEqual(AppTone.forBundle("com.example.Unknown"), .neutral)
        XCTAssertEqual(AppTone.forBundle(nil), .neutral)
    }

    func testEveryToneHasAnInstructionLine() {
        for tone in AppTone.allCases {
            XCTAssertFalse(tone.instructionLine.isEmpty, "\(tone)")
        }
    }
}
