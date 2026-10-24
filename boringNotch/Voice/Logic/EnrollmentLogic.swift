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
        switch (state.step, event) {
        case (.prompt(let index), .start):
            state.step = .recording(index)
            state.message = nil
        case (.recording(let index), .stop(let accepted)):
            if accepted {
                state.clips += 1
                state.quietAttempts = 0
                state.message = nil
                if state.redo {
                    state.redo = false
                    state.step = .computing
                } else {
                    state.step = index + 1 < promptCount ? .prompt(index + 1) : .computing
                }
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
        case (.computing, .scored(let outlier)):
            guard let index = outlier else {
                state.step = .done
                return
            }
            // The clip that does not match is dropped and read again. The cap is three re-reads: the fourth is refused.
            state.clips -= 1
            state.redos += 1
            if state.redos > maxQuietAttempts {
                state.step = .failed(tryAgainMessage)
                state.message = nil
            } else {
                state.step = .prompt(index)
                state.message = inconsistentMessage
                state.redo = true
                state.quietAttempts = 0
            }
        case (.prompt, .fail(let reason)), (.recording, .fail(let reason)), (.computing, .fail(let reason)):
            state.step = .failed(reason)
            state.message = nil
        case (_, .close):
            state = State()
        default:
            break
        }
    }

    /// True when a clip holds at least `minVoicedFrames` frames of 20 ms at or above `minLevelDBFS`. A single
    /// loud click is one frame, so it cannot lift a quiet prompt over the gate.
    static func clipAccepted(_ samples: [Float]) -> Bool {
        let frame = SpeakerGate.levelFrameSamples
        var voiced = 0
        var from = 0
        while from + frame <= samples.count {
            var sum: Float = 0
            for i in from..<(from + frame) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(frame)).squareRoot()
            if rms > 0, 20 * log10(rms) >= minLevelDBFS { voiced += 1 }
            from += frame
        }
        return voiced >= minVoicedFrames
    }

    /// The first clip whose cosine to the centroid of the other clips is below `minAgreement`, or nil.
    static func inconsistentClip(_ embeddings: [[Float]]) -> Int? {
        guard embeddings.count >= 2 else { return nil }
        for index in embeddings.indices {
            let others = embeddings.indices.filter { $0 != index }.map { embeddings[$0] }
            if SpeakerGate.cosine(embeddings[index], SpeakerGate.centroid(others)) < minAgreement { return index }
        }
        return nil
    }

    /// True when every embedding is at least `minAgreement` close to the centroid of the others.
    static func agrees(_ embeddings: [[Float]]) -> Bool {
        embeddings.count >= 2 && inconsistentClip(embeddings) == nil
    }

    /// The voiceprint, assembled: the centroid of the embeddings as Doubles, or nil when they do not agree.
    static func assemble(_ embeddings: [[Float]]) -> [Double]? {
        guard agrees(embeddings) else { return nil }
        return SpeakerGate.centroid(embeddings).map { Double($0) }
    }
}
