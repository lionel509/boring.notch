import Foundation

enum TakeOutcome: String {
    case pasted
    case discarded
    case nothingHeard
    case micSilent
    case noAudio
    case accessDenied
    case failed
}

/// The numbers for one take, logged as one line. Every field is a number, a Bool or an
/// enum, never text, so nothing the user said can reach the log (see LogPrivacyTests).
/// Unset counts and times stay -1.
struct TakeReport {
    var outcome: TakeOutcome = .failed
    var authStatus = -1
    var granted = false
    var tapChannels = -1
    var tapSampleRate = -1
    var bufferChannels = -1
    var bufferSampleRate = -1
    var buffers = -1
    var chunks = -1
    var peak: Float = -1
    var maxDB: Float = -1
    var floorDB: Float? = nil
    var voicedChunks = -1
    var verdict: MicVerdict = .noBuffers
    var configChanges = 0
    var convertFailures = 0
    var finals = -1
    var partials = -1
    var volatileTail = false
    var holdMs = -1
    var finalizeMs = -1
    var axMs = -1
    var modWaitMs = -1
    var pasteMs = -1
    var releaseToPasteMs = -1

    /// Copies what the mic meter measured.
    mutating func record(meter: MicLevelMeter) {
        buffers = meter.buffers
        chunks = meter.chunks
        peak = meter.peak
        maxDB = meter.maxDB
        floorDB = meter.floorDB
        voicedChunks = meter.voicedChunks
        verdict = meter.verdict
        bufferChannels = meter.firstChannels
        bufferSampleRate = Int(meter.firstSampleRate)
    }

    var line: String {
        let floorText = floorDB.map { String(format: "%.1f", $0) } ?? "none"
        return [
            "take outcome=\(outcome.rawValue)",
            "verdict=\(verdict.rawValue)",
            "auth=\(authStatus)",
            "granted=\(granted ? 1 : 0)",
            "tap=\(tapChannels)ch/\(tapSampleRate)Hz",
            "buf=\(bufferChannels)ch/\(bufferSampleRate)Hz",
            "buffers=\(buffers)",
            "chunks=\(chunks)",
            "peak=\(String(format: "%.4f", peak))",
            "max_db=\(String(format: "%.1f", maxDB))",
            "floor_db=\(floorText)",
            "voiced=\(voicedChunks)",
            "config_changes=\(configChanges)",
            "convert_failures=\(convertFailures)",
            "finals=\(finals)",
            "partials=\(partials)",
            "volatile_tail=\(volatileTail ? 1 : 0)",
            "hold_ms=\(holdMs)",
            "finalize_ms=\(finalizeMs)",
            "ax_ms=\(axMs)",
            "mod_wait_ms=\(modWaitMs)",
            "paste_ms=\(pasteMs)",
            "release_to_paste_ms=\(releaseToPasteMs)",
        ].joined(separator: " ")
    }
}
