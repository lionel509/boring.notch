import Foundation

/// The register the cleanup should keep, picked from the frontmost app's bundle id.
enum AppTone: String, CaseIterable, Equatable {
    case chat, email, code, notes, neutral

    static func forBundle(_ id: String?) -> AppTone {
        guard let id else { return .neutral }
        if chatApps.contains(id) { return .chat }
        if emailApps.contains(id) { return .email }
        if codeApps.contains(id) { return .code }
        if notesApps.contains(id) { return .notes }
        return .neutral
    }

    var instructionLine: String {
        switch self {
        case .chat: return "This is a chat message: keep it short and casual, and keep the speaker's own phrasing."
        case .email: return "This is an email: keep a polite, plain register and full sentences."
        case .code: return "This is code or a terminal: keep identifiers, symbols and casing exactly as spoken."
        case .notes: return "This is a note or document: keep clean prose with normal capitalization."
        case .neutral: return "Keep the speaker's wording and register."
        }
    }

    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS",
        "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp",
    ]
    private static let emailApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook"]
    private static let codeApps: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]
    private static let notesApps: Set<String> = [
        "md.obsidian", "com.apple.Notes", "com.apple.TextEdit", "com.apple.iWork.Pages",
    ]
}
