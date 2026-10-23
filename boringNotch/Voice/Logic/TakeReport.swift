import Foundation

/// How much the Mac's other audio is turned down during a take (#17 U1). `.mid` is the voice-processing level.
enum DuckLevel: String {
    case off, mid
}

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
    /// U5 / v4-3: the cloud path and the rewrite. Numbers, Bools and enums only (I2).
    var engineStartMs = -1
    var firstPartialMs = -1
    var sttMs = -1
    var sttSource: SttSource = .none
    var sttSeconds: Float = -1
    var sttCostMicroUSD = -1
    /// Release to the first successful swap of the rewrite.
    var firstCleanupMs = -1
    var llmFirstTokenMs = -1
    var llmTotalMs = -1
    var llmPromptTokens = -1
    var llmCompletionTokens = -1
    var swaps = -1
    var maxSwapMs = -1
    var mechanism: RewriteMechanism = .none
    var rewrite: RewriteOutcome = .none
    var cleanupSource: CleanupSource = .none
    var cleanupSkip: CleanupSkip = .none
    var tone: AppTone = .neutral
    var dictionaryWords = -1
    var cloud = false
    /// #13 r5 / U2: whether an OpenRouter key was read at the press, and whether voice processing is on.
    var hasKey = false
    var voiceProcessing = false
    /// #17 U1: the speaker gate, the segments it dropped, and whether the mic runs in Voice Isolation.
    var speakerGate = false
    var speakerDropped = -1
    var voiceIsolation = false
    /// #17 U1: the keep mode, the number of speakers labelled, the process CPU share of the take (%) and the
    /// resident-memory change over it (MB), and the ducking level. Printed only once a take sets `speakerMode`.
    var speakerMode: SpeakerMode? = nil
    var speakers = -1
    var cpuPct: Double = -1
    var rssDeltaMB = -1
    var ducking: DuckLevel = .off

    /// Copies what the mic meter measured.
    mutating func record(meter: MicLevelMeter) {
        buffers = meter.buffers
        chunks = meter.chunks
        peak = meter.peak
        maxDB = meter.maxDB
        floorDB = meter.floorDB
        voicedChunks = meter.voicedChunks
        verdict = meter.verdict
        // Only a take that got a buffer has a buffer format. Otherwise the fields stay -1.
        if meter.buffers > 0 {
            bufferChannels = meter.firstChannels
            bufferSampleRate = Int(meter.firstSampleRate)
        }
    }

    var line: String {
        let floorText = floorDB.map { String(format: "%.1f", $0) } ?? "none"
        return ([
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
            "engine_start_ms=\(engineStartMs)",
            "first_partial_ms=\(firstPartialMs)",
            "stt_ms=\(sttMs)",
            "stt=\(sttSource.rawValue)",
            "stt_s=\(String(format: "%.2f", sttSeconds))",
            "stt_uusd=\(sttCostMicroUSD)",
            "first_cleanup_ms=\(firstCleanupMs)",
            "llm_ttft_ms=\(llmFirstTokenMs)",
            "llm_ms=\(llmTotalMs)",
            "llm_in=\(llmPromptTokens)",
            "llm_out=\(llmCompletionTokens)",
            "swaps=\(swaps)",
            "max_swap_ms=\(maxSwapMs)",
            "mech=\(mechanism.rawValue)",
            "rewrite=\(rewrite.rawValue)",
            "cleanup=\(cleanupSource.rawValue)",
            "skip=\(cleanupSkip.rawValue)",
            "tone=\(tone.rawValue)",
            "dict=\(dictionaryWords)",
            "cloud=\(cloud ? 1 : 0)",
            "key=\(hasKey ? 1 : 0)",
            "vp=\(voiceProcessing ? 1 : 0)",
            "gate=\(speakerGate ? "on" : "off")",
            "dropped=\(speakerDropped)",
            "vi=\(voiceIsolation ? "on" : "off")",
        ] + speakerWords).joined(separator: " ")
    }

    /// The #17 U1 keys, empty until a take sets the mode, so takes without a speaker mode keep their old line.
    private var speakerWords: [String] {
        guard let speakerMode else { return [] }
        return [
            "mode=\(speakerMode.rawValue)",
            "speakers=\(speakers)",
            "cpu=\(String(format: "%.1f", cpuPct))%",
            "rss=\(rssDeltaMB >= 0 ? "+" : "")\(rssDeltaMB)MB",
            "iso=\(voiceIsolation ? "on" : "off")",
            "duck=\(ducking.rawValue)",
        ]
    }
}
