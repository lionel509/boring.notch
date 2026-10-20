import AppKit
import XCTest
@testable import VoiceDictationLogic

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Every test uses a private named pasteboard, never `.general`.
final class PasteboardSnapshotTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("bn-test-\(UUID().uuidString)"))
        pasteboards.append(pb)
        return pb
    }

    override func tearDown() {
        for pb in pasteboards { pb.releaseGlobally() }
        pasteboards = []
        super.tearDown()
    }

    private static let blobType = NSPasteboard.PasteboardType("com.example.blob")

    func testRoundTripOfTwoItems() {
        let pb = makePasteboard()
        pb.clearContents()
        let first = NSPasteboardItem()
        first.setString("hi there", forType: .string)
        let second = NSPasteboardItem()
        second.setData(Data("{\\rtf1 x}".utf8), forType: .rtf)
        second.setData(Data([0, 1, 2, 255]), forType: Self.blobType)
        pb.writeObjects([first, second])

        let original = PasteboardSnapshot.take(from: pb)
        XCTAssertEqual(original.items.count, 2)
        XCTAssertEqual(original.items[0][.string], Data("hi there".utf8))
        XCTAssertEqual(original.items[1][.rtf], Data("{\\rtf1 x}".utf8))
        XCTAssertEqual(original.items[1][Self.blobType], Data([0, 1, 2, 255]))

        PasteboardSnapshot.write("dictated", to: pb)
        original.restore(to: pb, ifChangeCountIs: pb.changeCount)
        XCTAssertEqual(PasteboardSnapshot.take(from: pb), original)
    }

    /// Eight types in a fixed, non-sorted order. A Dictionary-based restore matches this order by
    /// chance about once in 40,320 runs, so the test is red on essentially every run before the fix.
    func testRestoreKeepsTypeOrder() {
        let pb = makePasteboard()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("{\\rtf1 hi}".utf8), forType: .rtf)
        item.setString("hi", forType: .string)
        for name in ["t4", "t1", "t6", "t2", "t5", "t3"] {
            item.setData(Data(name.utf8), forType: NSPasteboard.PasteboardType("com.example.\(name)"))
        }
        pb.writeObjects([item])
        let originalOrder = pb.pasteboardItems?.first?.types ?? []
        XCTAssertGreaterThanOrEqual(originalOrder.count, 8)

        let snapshot = PasteboardSnapshot.take(from: pb)
        let change = PasteboardSnapshot.write("transcript", to: pb)
        XCTAssertTrue(snapshot.restore(to: pb, ifChangeCountIs: change))

        XCTAssertEqual(pb.pasteboardItems?.first?.types ?? [], originalOrder, "type order changed on restore")
    }

    func testWriteReturnsCurrentChangeCount() {
        let pb = makePasteboard()
        let count = PasteboardSnapshot.write("x", to: pb)
        XCTAssertEqual(count, pb.changeCount)
        XCTAssertEqual(pb.string(forType: .string), "x")
    }

    func testRestoreRefusesWhenChangeCountMoved() {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("before", forType: .string)
        let snapshot = PasteboardSnapshot.take(from: pb)

        let change = PasteboardSnapshot.write("dictated", to: pb)
        pb.clearContents()
        pb.setString("user copy", forType: .string)

        XCTAssertFalse(snapshot.restore(to: pb, ifChangeCountIs: change))
        XCTAssertEqual(pb.string(forType: .string), "user copy")
    }

    func testEmptyPasteboardRoundTrip() {
        let pb = makePasteboard()
        pb.clearContents()
        let snapshot = PasteboardSnapshot.take(from: pb)
        XCTAssertEqual(snapshot.items, [])

        let change = PasteboardSnapshot.write("x", to: pb)
        XCTAssertTrue(snapshot.restore(to: pb, ifChangeCountIs: change))
        XCTAssertEqual(PasteboardSnapshot.take(from: pb), snapshot)
        XCTAssertTrue(pb.pasteboardItems?.isEmpty ?? true)
    }

    func testPropertyRandomItemsRoundTrip() {
        var rng = SplitMix64(state: 0xC11B)
        let pool: [NSPasteboard.PasteboardType] = [
            .string, .rtf, Self.blobType, NSPasteboard.PasteboardType("com.example.other"),
        ]
        let pb = makePasteboard()
        for round in 0..<100 {
            pb.clearContents()
            var items: [NSPasteboardItem] = []
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                let item = NSPasteboardItem()
                let types = pool.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng))
                for type in types {
                    let bytes = Data((0..<Int.random(in: 1...64, using: &rng)).map { _ in
                        UInt8.random(in: 0...255, using: &rng)
                    })
                    item.setData(bytes, forType: type)
                }
                items.append(item)
            }
            if !items.isEmpty { pb.writeObjects(items) }

            let original = PasteboardSnapshot.take(from: pb)
            let change = PasteboardSnapshot.write("x", to: pb)
            XCTAssertTrue(original.restore(to: pb, ifChangeCountIs: change), "round \(round)")
            XCTAssertEqual(PasteboardSnapshot.take(from: pb), original, "round \(round)")
        }
    }
}
