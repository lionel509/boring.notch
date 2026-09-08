//
//  FlipDeck.swift
//  boringNotch
//
//  The split-flap board the notch cycles its pages on.
//

import SwiftUI

/// Cycles a list of pages the way an old departure board does: one page on screen, the next
/// rolling up from below on a timer.
///
/// Extracted from the stats strip so the strip and the tabs share one mechanic rather than
/// two that drift apart. Generic over the page type because the strip flips an enum and a tab
/// flips its sub-pages.
///
/// Showing exactly one page at a time is also what keeps the tabs cheap: `onPageChange` fires
/// as pages rotate, so a sub-page's manager runs only while that page is actually on screen.
/// Thirteen sub-pages therefore cost about what one does.
struct FlipDeck<Page: Hashable, Content: View>: View {
    let pages: [Page]
    /// The visible page. A binding, not internal state, so a rail or a keyboard can drive the
    /// same deck the timer does — one source of truth rather than two that drift.
    @Binding var current: Page?
    /// Seconds per page. Zero or fewer holds the first page indefinitely.
    let interval: Double
    /// Called with (leaving, arriving) whenever the visible page changes — including the
    /// first appearance and the final disappearance, where the other side is `nil`.
    var onPageChange: ((Page?, Page?) -> Void)?
    @ViewBuilder let content: (Page) -> Content

    @State private var isHeld = false
    @State private var timer: Timer?
    @State private var isFlipping = false
    @State private var flipReset: Task<Void, Never>?

    /// A roll implies physical motion. When the user has asked for less of it, the page still
    /// changes — it just cross-fades instead of travelling.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let current {
                content(current)
                    // Keyed on the page so SwiftUI treats a flip as a swap, not a redraw.
                    .id(current)
                    .transition(transition)
                    // Every figure inside stops running its own numeric roll for the length of
                    // the move, so the page travels as one object instead of leaving digits
                    // behind mid-animation.
                    .environment(\.panelIsFlipping, isFlipping)
            }
        }
        // Hovering holds the current page — nothing is more annoying than a number flipping
        // away while it is being read. Clicking advances by hand.
        .onHover { isHeld = $0 }
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .onAppear {
            onPageChange?(nil, current)
            start()
        }
        .onDisappear {
            stop()
            onPageChange?(current, nil)
        }
        // The set of pages can change underneath us — a page with nothing to say is not a
        // page — so the timer is rebuilt whenever the deck does.
        .onChange(of: pages) { _, _ in start() }
        .onChange(of: interval) { _, _ in start() }
        // Restart the countdown on *every* page change, whoever caused it. Without this the
        // timer keeps its original schedule, so switching by hand a moment before it was due
        // gets the page yanked away almost immediately — the interval is meant to be time
        // spent looking at a page, not time since the deck started.
        .onChange(of: current) { _, _ in start() }
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity))
    }

    private func advance() {
        guard pages.count > 1,
              let leaving = current,
              let index = pages.firstIndex(of: leaving) else { return }
        let next = pages[(index + 1) % pages.count]
        // Snappy and short. A split-flap board goes clack; a 0.42 s eased slide reads as the
        // row being dragged rather than flipped.
        isFlipping = true
        flipReset?.cancel()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.22, extraBounce: 0)) {
            current = next
        }
        onPageChange?(leaving, next)
        flipReset = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            isFlipping = false
        }
    }

    /// Same discipline as every other timer here: stored, guarded, invalidated on the way out.
    /// A closed notch flips nothing.
    private func start() {
        stop()
        guard pages.count > 1, interval > 0 else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                guard !isHeld else { return }
                advance()
            }
        }
        // .common so the deck keeps ticking while a scroll or drag is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
