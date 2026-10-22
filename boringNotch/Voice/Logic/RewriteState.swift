//
//  RewriteState.swift
//  boringNotch
//

import Foundation

/// How the helper moves the text for one take (chosen per take from the focused field).
enum RewriteMechanism: String {
    case none, ax, axSelectType, keys
}

enum RewriteOutcome: String {
    case none, completed, aborted, timedOut, reverted, failed
}

enum CleanupSource: String {
    case none, cloud, foundation, raw
}

enum SttSource: String {
    case none, assemblyai, voxtral, apple
}

/// Everything that can happen during a take's rewrite. The reducer decides what to do next.
enum RewriteEvent: Equatable {
    case sttArrived(String, SttSource)
    case sttFailed
    case appleFinal(String)
    /// The cumulative cleanup text so far, not a delta.
    case tokens(String)
    case streamEnded
    case streamFailed
    case foundationResult(String?)
    /// The helper's reply code for the last swap: 0 ok, 1 selectFailed, 2 setFailed, 3 verifyMismatch,
    /// 4 noFocus, 5 focusMoved, 6 notTrusted. Only 0 changes the text.
    case swapResult(Int)
    case userTouched
    case deadline
    case cancelled
}

/// What the caller must do. Each swap, stream and revert is started by exactly one effect.
enum RewriteEffect: Equatable {
    case swap(to: String)
    case startStream(input: String)
    case startFoundation(input: String)
    case revert(to: String)
    case finish(RewriteOutcome)
}

/// The state of one take's rewrite. `committed` is the text the reducer last swapped in successfully.
struct RewriteState: Equatable {
    enum Stage: Equatable { case awaitingSTT, streaming, finishing, ended }
    enum FlightKind: Equatable { case stageA, final, revert }
    /// A swap that was sent and whose reply has not come back yet.
    struct Flight: Equatable {
        var target: String
        var kind: FlightKind
    }

    var stage: Stage = .awaitingSTT
    var committed: String
    var stageAText: String? = nil
    var outcome: RewriteOutcome = .none
    var sttSource: SttSource = .none
    var cleanupSource: CleanupSource = .none
    var streamedText: String? = nil
    var sawToken = false
    var sttFailed = false
    var applePending: String? = nil
    var inFlight: Flight? = nil
    var awaitingFoundation = false
    /// A stream or foundation event that arrived while a swap was in flight; replayed when the reply lands.
    var deferred: RewriteEvent? = nil
}

/// The pure reducer for I4 (never lose a take). Every path ends in exactly one `.finish`. After that, every
/// event is ignored.
enum RewriteReducer {
    static func reduce(_ s: inout RewriteState, _ e: RewriteEvent) -> [RewriteEffect] {
        guard s.stage != .ended else { return [] }
        if s.inFlight != nil {
            switch e {
            case .streamEnded, .streamFailed, .foundationResult:
                s.deferred = e
                return []
            default:
                break
            }
        }

        switch e {
        case .sttArrived(let raw, let source):
            guard s.stage == .awaitingSTT else { return [] }
            let text = RewritePlanner.normalize(raw)
            if isBlank(text) { return reduce(&s, .sttFailed) }
            s.sttSource = source
            return start(&s, text: text)

        case .sttFailed:
            guard s.stage == .awaitingSTT else { return [] }
            s.sttFailed = true
            return settleFromApple(&s)

        case .appleFinal(let text):
            guard s.stage == .awaitingSTT else { return [] }
            s.applePending = RewritePlanner.normalize(text)
            return settleFromApple(&s)

        case .tokens(let text):
            guard s.stage == .streaming else { return [] }
            s.streamedText = text
            s.sawToken = true
            s.cleanupSource = .cloud
            return []

        case .streamEnded:
            guard s.stage == .streaming else { return [] }
            let full = s.streamedText ?? s.stageAText ?? s.committed
            if isBlank(full) || full == s.committed { return finish(&s, .completed) }
            s.stage = .finishing
            s.inFlight = RewriteState.Flight(target: full, kind: .final)
            return [.swap(to: full)]

        case .streamFailed:
            guard s.stage == .streaming else { return [] }
            s.stage = .finishing
            if s.sawToken, let stageA = s.stageAText {
                s.inFlight = RewriteState.Flight(target: stageA, kind: .revert)
                return [.revert(to: stageA)]
            }
            s.awaitingFoundation = true
            return [.startFoundation(input: s.stageAText ?? s.committed)]

        case .foundationResult(let text):
            guard s.awaitingFoundation else { return [] }
            s.awaitingFoundation = false
            guard let text, !isBlank(text), text != s.committed else { return finish(&s, .completed) }
            s.cleanupSource = .foundation
            s.inFlight = RewriteState.Flight(target: text, kind: .final)
            return [.swap(to: text)]

        case .swapResult(let code):
            guard let flight = s.inFlight else { return [] }
            s.inFlight = nil
            if code != 0 {
                return finish(&s, code == 4 || code == 5 ? .aborted : .failed)
            }
            s.committed = flight.target
            switch flight.kind {
            case .stageA:
                break
            case .final:
                return finish(&s, .completed)
            case .revert:
                return finish(&s, .reverted)
            }
            guard let deferred = s.deferred else { return [] }
            s.deferred = nil
            return reduce(&s, deferred)

        case .userTouched:
            return finish(&s, .aborted)

        case .deadline:
            return finish(&s, .timedOut)

        case .cancelled:
            return finish(&s, .aborted)
        }
    }

    // MARK: - Private

    /// Makes `text` the Stage-A text and starts the stream on it. The swap is skipped when the field already shows it.
    private static func start(_ s: inout RewriteState, text: String) -> [RewriteEffect] {
        s.stage = .streaming
        s.stageAText = text
        guard text != s.committed else { return [.startStream(input: text)] }
        s.inFlight = RewriteState.Flight(target: text, kind: .stageA)
        return [.swap(to: text), .startStream(input: text)]
    }

    /// Apple's final text is the fallback once the cloud STT has failed. Both must be in before anything starts.
    private static func settleFromApple(_ s: inout RewriteState) -> [RewriteEffect] {
        guard s.sttFailed, let apple = s.applePending else { return [] }
        if isBlank(apple) { return finish(&s, .failed) }
        s.sttSource = .apple
        return start(&s, text: apple)
    }

    private static func finish(_ s: inout RewriteState, _ outcome: RewriteOutcome) -> [RewriteEffect] {
        s.stage = .ended
        s.outcome = outcome
        s.inFlight = nil
        s.deferred = nil
        s.awaitingFoundation = false
        return [.finish(outcome)]
    }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
