import Foundation

/// One log line per ghost-text event. Numbers and enum names only: never field or suggestion text.
enum GhostTextEvent: String, CaseIterable {
    case call, shown, accepted, dismissed, dropped

    static func line(_ event: GhostTextEvent, callsTotal: Int) -> String {
        "ghost event=\(event.rawValue) calls=\(callsTotal)"
    }
}
