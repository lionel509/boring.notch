//
//  GhostTextOverlay.swift
//  boringNotch
//

import AppKit
import CoreText

/// #60: draws one line at an exact baseline. NSTextField's cell inset the first glyph by about 2 pt.
private final class GhostTextView: NSView {
    var text = ""
    var font: NSFont = .systemFont(ofSize: 13)
    var baseline: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.systemGray]))
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: 0, y: baseline)
        CTLineDraw(line, ctx)
    }
}

/// A non-activating, click-through panel that draws the gray suggestion just after the caret.
/// Placement is decided by `GhostTextGeometry`; this panel only shows the frame it is given.
@MainActor
final class GhostTextOverlay {
    static let shared = GhostTextOverlay()

    private var panel: NSPanel?
    private let label = GhostTextView()

    private init() {}

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = label
        return panel
    }

    /// Typographic width and line height of `text` in `font`, measured with the CTLine the view draws (#60).
    static func textSize(_ text: String, font: NSFont) -> CGSize {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGSize(width: ceil(width), height: ceil(font.ascender - font.descender))
    }

    /// `frame` is in Cocoa screen coordinates, already fitted to the field by `GhostTextGeometry.overlayFrame`.
    func show(_ text: String, frame: CGRect, font: NSFont) {
        let panel = panel ?? makePanel()
        self.panel = panel

        label.text = text
        label.font = font
        label.baseline = GhostTextGeometry.baselineInFrame(descent: -font.descender)
        panel.setFrame(frame, display: false)
        label.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
