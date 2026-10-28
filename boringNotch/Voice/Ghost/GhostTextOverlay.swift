//
//  GhostTextOverlay.swift
//  boringNotch
//

import AppKit

/// A non-activating, click-through panel that draws the gray suggestion just after the caret.
/// Placement is decided by `GhostTextGeometry`; this panel only shows the frame it is given.
@MainActor
final class GhostTextOverlay {
    static let shared = GhostTextOverlay()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

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
        label.textColor = .systemGray
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        panel.contentView = label
        return panel
    }

    /// What the label needs for `text` in `font`, rounded up plus 2 pt so pixel rounding never clips (#47 round 12).
    static func textSize(_ text: String, font: NSFont) -> CGSize {
        let measure = NSTextField(labelWithString: text)
        measure.font = font
        measure.lineBreakMode = .byClipping
        let size = measure.intrinsicContentSize
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    /// `frame` is in Cocoa screen coordinates, already fitted to the field by `GhostTextGeometry.overlayFrame`.
    func show(_ text: String, frame: CGRect, font: NSFont) {
        let panel = panel ?? makePanel()
        self.panel = panel

        label.stringValue = text
        label.font = font
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
