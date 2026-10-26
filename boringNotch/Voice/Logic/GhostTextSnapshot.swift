import Foundation

/// What the unsandboxed helper reads from the focused field. JSON keys are exactly the property names.
/// Caret coordinates are Accessibility screen coordinates: origin at the top-left of the primary display, y grows downward.
struct GhostTextSnapshot: Codable, Equatable {
    var bundleID: String = ""
    var appName: String = ""
    var windowTitle: String = ""
    var role: String = ""
    var subrole: String = ""
    var isSecure: Bool = false
    /// Absent when the field is secure or its value cannot be read.
    var textBeforeCaret: String? = nil
    var caretX: Double? = nil
    var caretY: Double? = nil
    var caretWidth: Double? = nil
    var caretHeight: Double? = nil

    var hasCaret: Bool {
        guard let x = caretX, let y = caretY, let w = caretWidth, let h = caretHeight else { return false }
        return x.isFinite && y.isFinite && w.isFinite && h.isFinite && h > 0
    }

    static func decode(_ json: String) -> GhostTextSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GhostTextSnapshot.self, from: data)
    }
}
