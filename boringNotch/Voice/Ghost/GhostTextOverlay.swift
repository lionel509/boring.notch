//
//  GhostTextOverlay.swift
//  boringNotch
//

import AppKit

/// A non-activating, click-through panel that draws the gray suggestion just after the caret.
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
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        panel.contentView = label
        return panel
    }

    /// `axCaret` is in AX screen coordinates: origin at the top-left of the primary display.
    func show(_ text: String, axCaret: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        label.stringValue = text
        label.font = .systemFont(ofSize: min(max(axCaret.height * 0.72, 11), 22))

        let cocoaBottom = primary.frame.height - (axCaret.origin.y + axCaret.height)
        let x = axCaret.maxX + 1
        let point = CGPoint(x: x, y: cocoaBottom)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? primary
        let size = label.intrinsicContentSize
        let maxWidth = screen.frame.maxX - x - 8
        let width = min(size.width, maxWidth)
        let y = cocoaBottom - (size.height - axCaret.height) / 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
