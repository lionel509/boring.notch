import XCTest
@testable import VoiceDictationLogic

/// #17 U2b: the XPC hop carries Float32 little-endian bytes, and the take releases the helper's model
/// only when this take asked for an embedding (an idle app must not wake the helper to tell it to release).
final class SpeakerWireTests: XCTestCase {
    func testPackIsFloat32LittleEndianAndRoundTrips() {
        let values = (0..<256).map { Float($0) / 255 - 0.5 }
        let data = SpeakerWire.pack(values)
        XCTAssertEqual(data.count, 256 * 4)
        XCTAssertEqual(SpeakerWire.floats(from: data), values)
    }

    func testOneIsTheLittleEndianBytesOfFloat32One() {
        XCTAssertEqual(Array(SpeakerWire.pack([1])), [0x00, 0x00, 0x80, 0x3F])
    }

    func testFloatsRejectNilAndPartialFloats() {
        XCTAssertNil(SpeakerWire.floats(from: nil))
        XCTAssertNil(SpeakerWire.floats(from: Data([1, 2, 3])))
        XCTAssertEqual(SpeakerWire.floats(from: Data()), [])
    }

    func testEmbeddingNeedsExactly256Floats() {
        XCTAssertNil(SpeakerWire.embedding(from: nil))
        XCTAssertNil(SpeakerWire.embedding(from: SpeakerWire.pack([Float](repeating: 0, count: 255))))
        XCTAssertNil(SpeakerWire.embedding(from: SpeakerWire.pack([Float](repeating: 0, count: 257))))
        XCTAssertEqual(SpeakerWire.embedding(from: SpeakerWire.pack([Float](repeating: 0.5, count: 256)))?.count, 256)
    }

    func testIdleTakeReleasesNothing() {
        var lease = SpeakerModelLease()
        XCTAssertFalse(lease.endTake(), "a take that never embedded must not wake the helper")
    }

    func testEmbeddingTakeReleasesOnceAtItsEnd() {
        var lease = SpeakerModelLease()
        lease.noteEmbedding()
        lease.noteEmbedding()
        XCTAssertTrue(lease.endTake())
        XCTAssertFalse(lease.endTake(), "finish then cancel must not release twice")
    }

    func testCancelAfterEmbeddingReleases() {
        var lease = SpeakerModelLease()
        lease.noteEmbedding()
        XCTAssertTrue(lease.endTake())
    }

    func testNextTakeReacquiresAfterRelease() {
        var lease = SpeakerModelLease()
        lease.noteEmbedding()
        XCTAssertTrue(lease.endTake())
        lease.noteEmbedding()
        XCTAssertTrue(lease.endTake())
    }
}
