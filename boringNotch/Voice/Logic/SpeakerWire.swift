import Foundation

/// The bytes that cross the XPC hop to the speaker helper (#17 U2b): Float32 little-endian, no header. The
/// helper target cannot see this folder, so it carries its own copy of the same four lines.
enum SpeakerWire {
    /// Width of a WeSpeaker v2 embedding.
    static let embeddingCount = 256

    static func pack(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Every Float32 in `data`. nil for nil data or a length that is not a whole number of floats.
    static func floats(from data: Data?) -> [Float]? {
        guard let data, data.count % 4 == 0 else { return nil }
        return stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = data.subdata(in: offset..<offset + 4).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
    }

    /// One embedding: exactly `embeddingCount` finite floats, otherwise nil. A NaN or infinite reply is no embedding,
    /// so its segment is kept rather than scored as "not Me" (#17 U2b).
    static func embedding(from data: Data?) -> [Float]? {
        guard let values = floats(from: data), values.count == embeddingCount, values.allSatisfy(\.isFinite) else {
            return nil
        }
        return values
    }
}

/// Whether this take asked the helper for an embedding. Finish and cancel both end a take through `endTake`;
/// only a take that embedded releases the helper's model, so an idle app never wakes the helper to release.
struct SpeakerModelLease {
    private var used = false
    /// True from `begin` until `endTake`. A window that arrives after the take ended finds the lease closed and never
    /// reaches the helper, so it cannot reload the model with nothing left to release it (#17 U2b).
    private(set) var isOpen = false

    mutating func begin() {
        isOpen = true
        used = false
    }

    mutating func noteEmbedding() {
        used = true
    }

    /// True when the helper must be told to release. Closes the take and resets, so a second end of the same take
    /// returns false.
    mutating func endTake() -> Bool {
        isOpen = false
        defer { used = false }
        return used
    }
}
