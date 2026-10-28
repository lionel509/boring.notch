//
//  GhostTextLog.swift
//  boringNotch
//

import Defaults
import os

/// The only ghost-text file that logs. One func, one GhostTextEvent per line; .notice so `log show` keeps it.
enum GhostTextLog {
    private static let logger = Logger(subsystem: "theboringteam.boringnotch", category: "GhostText")
    static func record(_ event: GhostTextEvent, reason: GhostTextEvent.Reason? = nil, check: GhostTextPolicy.Check? = nil, insertResult: Int? = nil, axError: Int? = nil, app: String? = nil, value: String? = nil, snapshotApp: String? = nil, latencyMs: Int? = nil) { logger.notice("\(GhostTextEvent.line(event, callsTotal: Defaults[.ghostTextCalls], reason: reason, check: check, insertResult: insertResult, axError: axError, app: app, value: value, snapshotApp: snapshotApp, latencyMs: latencyMs), privacy: .public)") }
}
