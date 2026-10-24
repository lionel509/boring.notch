//
//  EnrollmentLogic.swift
//  boringNotch
//
//  The pure part of voice enrolment (#17 U3): the level gate, the step transitions, the retry limit and the
//  voiceprint assembly. No AVFoundation, no Defaults, no clock. VoiceEnrollment drives the mic and the XPC
//  helper, and feeds the results through `reduce`.
//

import Foundation

enum EnrollmentLogic {
    static let promptCount = 3
    static let minLevelDBFS: Float = -35
    static let minAgreement = 0.25
    static let maxQuietAttempts = 3
    static let closerMessage = "Closer to the mic, please"
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
    }

    enum Event: Equatable {
        case start
        /// Recording stopped; the voiced level of what was captured (`SpeakerGate.levelDBFS`).
        case stop(levelDBFS: Float)
        /// The three clips were scored; true when they agree enough to be one voice.
        case scored(Bool)
        /// Something outside the logic failed (no microphone, helper unavailable).
        case fail(String)
        case close
    }

    /// Advances `state` by one event. Events that do not apply to the current step change nothing.
    static func reduce(_ state: inout State, _ event: Event) {
        switch (state.step, event) {
        case (.prompt(let index), .start):
            state.step = .recording(index)
            state.message = nil
        case (.recording(let index), .stop(let level)):
            if levelAccepted(level) {
                state.clips += 1
                state.quietAttempts = 0
                state.message = nil
                state.step = index + 1 < promptCount ? .prompt(index + 1) : .computing
            } else {
                state.quietAttempts += 1
                if state.quietAttempts >= maxQuietAttempts {
                    state.step = .failed(tryAgainMessage)
                    state.message = nil
                } else {
                    state.step = .prompt(index)
                    state.message = closerMessage
                }
            }
        case (.computing, .scored(let same)):
            state.step = same ? .done : .failed(tryAgainMessage)
        case (.prompt, .fail(let reason)), (.recording, .fail(let reason)), (.computing, .fail(let reason)):
            state.step = .failed(reason)
            state.message = nil
        case (_, .close):
            state = State()
        default:
            break
        }
    }

    /// True when a prompt's voiced level is loud enough to keep.
    static func levelAccepted(_ levelDBFS: Float) -> Bool {
        levelDBFS >= minLevelDBFS
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
