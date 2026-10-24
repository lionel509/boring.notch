import Foundation

/// The take's transcript as the results loop builds it (#17 U2b). A final keeps its text the moment it lands, before
/// its speaker embedding is awaited, so no final is ever in neither place. The volatile is the transcriber's latest
/// unconfirmed text. Key release captures both, so the paste is the transcript as it stood at that moment.
/// Pure: no model, no audio, no Defaults.
struct TakeTranscript {
    struct Tail: Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    /// What the transcript held at key release. Captured before any await.
    private struct Released {
        var finals: [LabelledSegment]
        var tail: LabelledSegment?
        var finalCount: Int
    }

    private(set) var finals: [LabelledSegment] = []
    private var volatile: Tail?
    private var released: Released?

    /// Whether the transcriber's latest unconfirmed text is not blank.
    var hasVolatile: Bool {
        volatile.map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    /// A final landed. Its text is kept now, and the volatile it confirms is cleared. Returns the index that
    /// `setEmbedding` fills in when the helper answers.
    mutating func land(text: String, start: Double, end: Double) -> Int {
        volatile = nil
        finals.append(LabelledSegment(text: text, start: start, end: end, embedding: nil, label: .unknown))
        return finals.count - 1
    }

    mutating func setEmbedding(_ embedding: [Float]?, at index: Int) {
        guard finals.indices.contains(index) else { return }
        finals[index].embedding = embedding
    }

    mutating func setVolatile(text: String, start: Double, end: Double) {
        volatile = Tail(text: text, start: start, end: end)
    }

    /// Key release. Captures the finals and the volatile tail, when it is not blank, and returns the tail's span
    /// so the caller can embed it.
    mutating func release() -> Tail? {
        let tail = hasVolatile ? volatile : nil
        released = Released(
            finals: finals,
            tail: tail.map { LabelledSegment(text: $0.text, start: $0.start, end: $0.end, embedding: nil, label: .unknown) },
            finalCount: finals.count)
        return tail
    }

    /// The tail's embedding, once its bounded wait has answered. nil when it did not answer in time.
    mutating func setTailEmbedding(_ embedding: [Float]?) {
        released?.tail?.embedding = embedding
    }

    /// The paste at key release: the finals as they stood then, followed by the tail.
    var releasePaste: [LabelledSegment] {
        guard let released else { return finals }
        return released.finals + (released.tail.map { [$0] } ?? [])
    }

    /// The segments for the final labelling. A finalized take keeps every final. An unfinalized take keeps the
    /// released tail, unless a final landed after release: that final is the tail's own sentence, so the tail is
    /// dropped rather than pasted twice.
    func segments(finalized: Bool) -> [LabelledSegment] {
        guard !finalized, let released, let tail = released.tail, finals.count == released.finalCount else {
            return finals
        }
        return finals + [tail]
    }

    /// Waits at most `seconds` for a tail embedding. A helper that never answers costs the paste this long, no more.
    static func boundedEmbedding(seconds: Double, _ embed: @escaping @Sendable () async -> [Float]?) async -> [Float]? {
        (await TimeoutRace.run(seconds: seconds, embed)) ?? nil
    }
}
