//
//  GhostTextLog.swift
//  boringNotch
//

import Defaults
import os

/// The only ghost-text file that logs. One func, one GhostTextEvent per line; .notice so `log show` keeps it.
enum GhostTextLog {
    private static let logger = Logger(subsystem: "theboringteam.boringnotch", category: "GhostText")
    static func record(_ event: GhostTextEvent) { logger.notice("\(GhostTextEvent.line(event, callsTotal: Defaults[.ghostTextCalls]), privacy: .public)") }
}
