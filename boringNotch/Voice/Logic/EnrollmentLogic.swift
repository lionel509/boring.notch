//
//  EnrollmentLogic.swift
//  boringNotch
//
//  The pure part of voice enrolment (#17 U3): the clip gate, the step transitions, the retry limit and the
//  voiceprint assembly. No AVFoundation, no Defaults, no clock. VoiceEnrollment drives the mic and the XPC
//  helper, and feeds the results through `reduce`.
//

import Foundation

enum EnrollmentLogic {
    static let promptCount = 3
    static let minLevelDBFS: Float = -35
    static let minVoicedFrames = 25
    static let minAgreement = 0.45
    static let maxQuietAttempts = 3
    static let closerMessage = "Closer to the mic, please"
    static let inconsistentMessage = "That one didn't match the other two. Read it again."
    static let tryAgainMessage = "Try again somewhere quieter"
    static let modelUnavailableMessage = "The speaker model is not available. Try again in a moment."

    enum Step: Equatable {
        case prompt(Int)
        case recording(Int)
        case computing
        case done
        case failed(String)
    }

    struct State: Equatable {
        var step: Step = .prompt(0)
        /// "Closer to the mic, please" after a quiet prompt, nil otherwise.
        var message: String?
        /// Quiet takes in a row on the current prompt.
        var quietAttempts = 0
        /// Accepted prompts so far.
        var clips = 0
        /// True while a prompt is being read again because its clip did not match the others.
        var redo = false
        /// Clips rejected for not matching the others, over the whole enrolment.
        var redos = 0
    }

    enum Event: Equatable {
        case start
        /// Recording stopped; `accepted` is `clipAccepted` of what was captured.
        case stop(accepted: Bool)
        /// The clips were scored: nil when they agree, else the index of the clip to read again.
        case scored(outlier: Int?)
        /// Something outside the logic failed (no microphone, helper unavailable).
        case fail(String)
        case close
    }

    /// Advances `state` by one event. Events that do not apply to the current step change nothing.
    static func reduce(_ state: inout State, _ event: Event) {
    }

    /// True when a clip holds at least `minVoicedFrames` frames of 20 ms at or above `minLevelDBFS`.
    static func clipAccepted(_ samples: [Float]) -> Bool {
        false
    }

    /// The first clip whose cosine to the centroid of the other clips is below `minAgreement`, or nil.
    static func inconsistentClip(_ embeddings: [[Float]]) -> Int? {
        nil
    }

    /// True when every embedding is at least `minAgreement` close to the centroid of the others.
    static func agrees(_ embeddings: [[Float]]) -> Bool {
        guard embeddings.count >= 2 else { return false }
        for index in embeddings.indices {
            let others = embeddings.indices.filter { $0 != index }.map { embeddings[$0] }
            if SpeakerGate.cosine(embeddings[index], SpeakerGate.centroid(others)) < minAgreement { return false }
        }
        return true
    }

    /// The voiceprint, assembled: the centroid of the embeddings as Doubles, or nil when they do not agree.
    static func assemble(_ embeddings: [[Float]]) -> [Double]? {
        guard agrees(embeddings) else { return nil }
        return SpeakerGate.centroid(embeddings).map { Double($0) }
    }
}
