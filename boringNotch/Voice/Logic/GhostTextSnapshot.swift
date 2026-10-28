import Foundation
import CoreGraphics

/// What the unsandboxed helper reads from the focused field. JSON keys are exactly the property names.
/// Caret and field coordinates are Accessibility screen coordinates: origin at the top-left of the primary display, y grows downward.
struct GhostTextSnapshot: Codable, Equatable {
    var bundleID: String = ""
    var appName: String = ""
    var windowTitle: String = ""
    var role: String = ""
    var subrole: String = ""
    var isSecure: Bool = false
    /// Absent when the field is secure or its value cannot be read.
    var textBeforeCaret: String? = nil
    /// UTF-16 offset of the caret in the field. Absent when the caret cannot be located.
    var caretLocation: Int? = nil
    /// True only when no non-blank text follows the caret.
    var caretAtEnd: Bool = false
    var caretX: Double? = nil
    var caretY: Double? = nil
    var caretWidth: Double? = nil
    var caretHeight: Double? = nil
    var fieldX: Double? = nil
    var fieldY: Double? = nil
    var fieldWidth: Double? = nil
    var fieldHeight: Double? = nil
    /// One-use id of the field this read found; the helper writes only there. Never logged, never sent to the model.
    var token: String? = nil
    /// The field's font at the character before the caret, from AXFont. Absent when the app doesn't expose it. Never logged, never sent to the model.
    var fontName: String? = nil
    /// The field's font at the character before the caret, from AXFont. Absent when the app doesn't expose it. Never logged, never sent to the model.
    var fontSize: Double? = nil

    private enum CodingKeys: String, CodingKey {
        case bundleID, appName, windowTitle, role, subrole, isSecure, textBeforeCaret, caretLocation, caretAtEnd
        case caretX, caretY, caretWidth, caretHeight, fieldX, fieldY, fieldWidth, fieldHeight, token, fontName, fontSize
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole) ?? ""
        isSecure = try c.decodeIfPresent(Bool.self, forKey: .isSecure) ?? false
        textBeforeCaret = try c.decodeIfPresent(String.self, forKey: .textBeforeCaret)
        caretLocation = try c.decodeIfPresent(Int.self, forKey: .caretLocation)
        caretAtEnd = try c.decodeIfPresent(Bool.self, forKey: .caretAtEnd) ?? false
        caretX = try c.decodeIfPresent(Double.self, forKey: .caretX)
        caretY = try c.decodeIfPresent(Double.self, forKey: .caretY)
        caretWidth = try c.decodeIfPresent(Double.self, forKey: .caretWidth)
        caretHeight = try c.decodeIfPresent(Double.self, forKey: .caretHeight)
        fieldX = try c.decodeIfPresent(Double.self, forKey: .fieldX)
        fieldY = try c.decodeIfPresent(Double.self, forKey: .fieldY)
        fieldWidth = try c.decodeIfPresent(Double.self, forKey: .fieldWidth)
        fieldHeight = try c.decodeIfPresent(Double.self, forKey: .fieldHeight)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
    }

    var hasCaret: Bool {
        guard let x = caretX, let y = caretY, let w = caretWidth, let h = caretHeight else { return false }
        return x.isFinite && y.isFinite && w.isFinite && h.isFinite && h > 0
    }

    /// The caret as a screen rect, or nil unless every coordinate is finite and the height is positive.
    var caretRect: CGRect? {
        guard hasCaret, let x = caretX, let y = caretY, let w = caretWidth, let h = caretHeight else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The focused field as a screen rect, or nil unless every coordinate is finite and the height is positive.
    var fieldRect: CGRect? {
        guard let x = fieldX, let y = fieldY, let w = fieldWidth, let h = fieldHeight else { return nil }
        guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func decode(_ json: String) -> GhostTextSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GhostTextSnapshot.self, from: data)
    }
}
