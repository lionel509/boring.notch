import Foundation

/// The answer to "transcribe this call?". Set by fn+Y, fn+N, fn+D while a call prompt is armed.
enum CallAnswer: Equatable, Sendable {
    case yes, no, never
    static let yKeyCode = 16, nKeyCode = 45, dKeyCode = 2   // kVK_ANSI_Y / _N / _D

    init?(keyCode: Int) {
        switch keyCode {
        case 16: self = .yes
        case 45: self = .no
        case 2: self = .never
        default: return nil
        }
    }
}

/// One process with its input running. `name` is set only when the old indicator would have named it.
struct MicClient: Equatable, Sendable {
    let bundleID: String
    let pid: Int32
    let name: String?
}

/// A call the notch can ask about. `id` is stable per service ("zoom", "meet"); `pid` is the mic-holding process, for #17's capture.
struct DetectedCall: Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let pid: Int32
    let viaBrowser: Bool
}
