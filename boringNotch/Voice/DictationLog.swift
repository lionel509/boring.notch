//
//  DictationLog.swift
//  boringNotch
//
//  The only place the voice code writes to the unified log. It takes a TakeReport,
//  so only numbers and enum codes can reach the log, never transcript text or audio.
//

import Foundation
import os

enum DictationLog {
    private static let logger = Logger(subsystem: "theboringteam.boringnotch", category: "Dictation")

    static func take(_ report: TakeReport) {
        logger.notice("\(report.line, privacy: .public)")
    }
}
