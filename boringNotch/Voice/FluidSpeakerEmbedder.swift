//
//  FluidSpeakerEmbedder.swift
//  boringNotch
//
//  The take's speaker embedder (#17 U2b). Every window goes to the unsandboxed XPC helper, which holds the
//  WeSpeaker model while a take needs it. The app loads no CoreML model, so its memory does not move with the
//  speaker gate, and the helper is asked for an embedding only by a take that has a voiceprint or a labelled mode.
//

import Foundation

actor FluidSpeakerEmbedder: SpeakerEmbedder {
    static let shared = FluidSpeakerEmbedder()

    /// Whether the current take has asked the helper for anything, so the end of the take releases it once.
    private var lease = SpeakerModelLease()

    /// The one scoring path: `SpeakerGate` normalises, windows and tiles the span, and each window is embedded
    /// by the helper. nil for an empty span. Throws when the helper cannot answer; the caller treats that as
    /// an unscorable segment and keeps it.
    func segmentEmbedding(_ samples16k: [Float]) async throws -> [Float]? {
        try await SpeakerGate.segmentEmbedding(samples16k) { window in
            self.lease.noteEmbedding()
            guard let embedding = await XPCHelperClient.shared.speakerEmbedding(window) else {
                throw SpeakerEmbedderError.helperUnavailable
            }
            return embedding
        }
    }

    /// Called at the end of every take. Releases the helper's model only when this take asked for one.
    func release() async {
        guard lease.endTake() else { return }
        await XPCHelperClient.shared.releaseSpeakerModel()
    }
}

enum SpeakerEmbedderError: Error {
    case helperUnavailable
}
