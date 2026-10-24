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

/// Which take holds the helper's speaker model, and whether a release is owed (#17 U2b, round 2). Takes are keyed
/// by ID, so a superseded take's end cannot close the live take. A release is owed from the first window that reaches
/// the helper until one is sent, and it is sent exactly once, at the first end after no take holds the lease. So a
/// superseded take's release waits for the live take to end instead of being forgotten.
struct SpeakerModelLease {
    /// The take that is running. nil once it has ended, or before any has begun.
    private(set) var holder: UUID?
    /// True when a window reached the helper and no release has been sent since.
    private(set) var owed = false

    mutating func begin(_ take: UUID) {
        holder = take
    }

    func isOpen(_ take: UUID) -> Bool {
        holder == take
    }

    /// Records a window for the take. Ignored unless the take holds the lease.
    mutating func noteEmbedding(_ take: UUID) {
        if holder == take { owed = true }
    }

    /// The take ended. Returns true exactly once: when no take holds the lease and a release is owed. An end from a
    /// take that no longer holds the lease only clears nothing; the owed release is still sent by the next end.
    mutating func endTake(_ take: UUID) -> Bool {
        if holder == take { holder = nil }
        guard holder == nil, owed else { return false }
        owed = false
        return true
    }
}
