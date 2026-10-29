import CoreGraphics

/// Pure overlay geometry for ghost text. Rects are in Accessibility coordinates (origin top-left of the
/// primary display, y grows down) unless a function says it returns Cocoa coordinates.
enum GhostTextGeometry {
    /// Minimum space to the right of the caret before a suggestion is shown.
    static let minRoom: CGFloat = 40

    /// Converts an Accessibility rect to Cocoa coordinates (origin bottom-left of the primary display).
    static func toCocoa(_ ax: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: ax.origin.x, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }

    /// True when the caret sits inside the field and there is at least `minRoom` to its right.
    static func hasRoom(caret: CGRect, field: CGRect) -> Bool {
        guard caret.midY >= field.minY, caret.midY <= field.maxY else { return false }
        guard caret.maxX >= field.minX - 2, caret.maxX <= field.maxX + 2 else { return false }
        return field.maxX - caret.maxX - 4 >= minRoom
    }

    /// #57: how far the caret or field may move after the overlay was drawn before the suggestion is dropped.
    static let driftTolerance: CGFloat = 2

    /// #57: true when the caret or field moved more than the tolerance since the overlay was drawn, or a rect is missing.
    static func drifted(drawnCaret: CGRect, drawnField: CGRect, nowCaret: CGRect?, nowField: CGRect?) -> Bool {
        guard let nowCaret, let nowField else { return true }
        func moved(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) > driftTolerance || abs(a.minY - b.minY) > driftTolerance
                || abs(a.width - b.width) > driftTolerance || abs(a.height - b.height) > driftTolerance
        }
        return moved(drawnCaret, nowCaret) || moved(drawnField, nowField)
    }

    /// Frame for the suggestion in Cocoa coordinates, or nil when there is no room at the caret.
    static func overlayFrame(caret: CGRect, field: CGRect, textSize: CGSize, primaryHeight: CGFloat) -> CGRect? {
        guard hasRoom(caret: caret, field: field) else { return nil }
        let x = caret.maxX + 2
        // Never draw less than what accept would insert.
        guard textSize.width <= field.maxX - x - 2 else { return nil }
        let rect = CGRect(x: x,
                          y: caret.midY - textSize.height / 2,
                          width: textSize.width,
                          height: textSize.height)
        return toCocoa(rect, primaryHeight: primaryHeight)
    }

    /// Round 12 (#47): the longest whole-word prefix of `text` that `overlayFrame` accepts, or nil when not even the
    /// first word fits. Leading whitespace (the join space) is kept. Never ellipsizes: what this returns is what accept inserts.
    static func fitWords(_ text: String, caret: CGRect, field: CGRect, width: (String) -> CGFloat) -> String? {
        let lead = String(text.prefix(while: { $0.isWhitespace }))
        let words = text.dropFirst(lead.count).split(separator: " ", omittingEmptySubsequences: true)
        var count = words.count
        while count > 0 {
            let candidate = lead + words.prefix(count).joined(separator: " ")
            if overlayFrame(caret: caret, field: field, textSize: CGSize(width: width(candidate), height: 1), primaryHeight: 0) != nil {
                return candidate
            }
            count -= 1
        }
        return nil
    }

    /// Font size that tracks the caret height, clamped to 11...22 points.
    static func fontSize(caretHeight: CGFloat) -> CGFloat {
        min(max(caretHeight * 0.72, 11), 22)
    }

    /// The field's own font size when the helper read one in 6...72 points, else the caret-height estimate.
    static func fontSize(fieldFontSize: Double?, caretHeight: CGFloat) -> CGFloat {
        if let s = fieldFontSize, s.isFinite, s >= 6, s <= 72 { return CGFloat(s) }
        return fontSize(caretHeight: caretHeight)
    }
}
