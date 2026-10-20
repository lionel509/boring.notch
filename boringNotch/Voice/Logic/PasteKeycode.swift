import Carbon
import Foundation

/// Finds the keycode that types V on the current keyboard layout, so Cmd-V is
/// pasted on the right key under Dvorak and similar layouts.
enum PasteKeycode {
    /// The ANSI V position. Used only when no layout data can be read.
    static let ansiV: UInt16 = 0x09

    /// The keycode whose output with Command held is `ch`, searched over the
    /// layout data. Nil when no keycode types it.
    static func keyCode(typing ch: Character, layoutData: Data) -> UInt16? {
        let target = String(ch).lowercased()
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())
        return layoutData.withUnsafeBytes { raw -> UInt16? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            for code in UInt16(0)..<128 {
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), commandState, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
                    chars.count, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return code
                }
            }
            return nil
        }
    }

    /// The keycode that types V on the active layout. Falls back to the ASCII-capable
    /// layout (some input methods have no Unicode layout data), then to the ANSI V position.
    static func currentV() -> UInt16 {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        for case let source? in sources {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                continue
            }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            if let code = keyCode(typing: "v", layoutData: data) {
                return code
            }
        }
        return ansiV
    }
}
