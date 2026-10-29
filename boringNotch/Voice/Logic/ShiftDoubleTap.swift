import Foundation

/// #56: two clean Shift taps accept. Feed every flagsChanged; call reset() on any keyDown, mouse down, scroll,
/// tap reset, synthetic event, or when a new suggestion is drawn.
struct ShiftDoubleTap: Equatable {
    static let window: TimeInterval = 0.40          // first press to second release
    static let shiftKeyCodes: Set<Int> = [56, 60]   // left, right
    private var firstPress: TimeInterval?
    private var taps = 0          // completed releases since firstPress
    private var down = false
    /// Set while a Shift is still held after the pattern broke (two Shifts held at once). No press counts until
    /// every Shift is up, or the release of the second Shift would look like a fresh press.
    private var blocked = false

    /// Clears the pattern. `blocked` is not touched: only the Shift keys themselves release it.
    mutating func reset() {
        firstPress = nil
        taps = 0
        down = false
    }

    /// Clears the pattern after the tap was disabled and events were lost. Unlike reset(), it re-derives the latch from
    /// the live Shift state, because the releases that would have cleared it may have been dropped.
    mutating func tapReset(shiftHeld: Bool) {
        reset()
        blocked = shiftHeld
    }

    /// True only on the release that completes the second clean tap inside the window.
    mutating func flagsChanged(keyCode: Int, flags: UInt64, now: TimeInterval) -> Bool {
        let isDown = flags & GhostTextLogic.shiftMask != 0
        if !isDown { blocked = false }
        // A Shift key with another real modifier (Control, Option or Command) held is not a clean tap.
        // Caps lock's bit is not in the mask, so caps lock never blocks a tap.
        if !Self.shiftKeyCodes.contains(keyCode)
            || flags & (GhostTextLogic.controlMask | GhostTextLogic.optionMask | GhostTextLogic.commandMask) != 0 {
            reset()
            return false
        }
        // A press starts a tap, or starts over when the first tap is spent or out of the window.
        if !down && isDown {
            if blocked {
                reset()
                return false
            }
            if taps == 1, let first = firstPress, now >= first, now - first <= Self.window {
                down = true
            } else {
                firstPress = now
                taps = 0
                down = true
            }
            return false
        }
        // A release completes one tap.
        if down && !isDown {
            down = false
            taps += 1
            if taps == 2, let first = firstPress {
                let inWindow = now >= first && now - first <= Self.window
                reset()
                return inWindow
            }
            return false
        }
        // Anything else (the other Shift pressed while one is held, or a stray release) breaks the pattern.
        // If a Shift is still down, block until all are up.
        blocked = isDown
        reset()
        return false
    }
}
