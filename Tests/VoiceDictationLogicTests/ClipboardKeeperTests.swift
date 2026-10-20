import AppKit
import XCTest
@testable import VoiceDictationLogic

/// Overlapping takes share one pending clipboard restore. Every test uses a private named pasteboard, never `.general`.
final class ClipboardKeeperTests: XCTestCase {
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

    private func userCopies(_ text: String, to pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func string(_ pb: NSPasteboard) -> String? {
        pb.string(forType: .string)
    }

    func testSecondTakeInRestoreWindowRestoresPreviousTranscript() {
        let pb = makePasteboard()
        userCopies("user's original clipboard", to: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("transcript A", to: pb)
        let changeB = keeper.write("transcript B", to: pb)

        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeA))
        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeB))
        XCTAssertEqual(string(pb), "user's original clipboard")
        XCTAssertNil(keeper.pending)
    }

    func testRestoreBeforeSecondTakeSnapshotsFresh() {
        let pb = makePasteboard()
        userCopies("orig", to: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("take A", to: pb)
        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeA))
        XCTAssertEqual(string(pb), "orig")

        let changeB = keeper.write("take B", to: pb)
        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeB))
        XCTAssertEqual(string(pb), "orig")
    }

    func testUserCopyBetweenTakesWins() {
        let pb = makePasteboard()
        userCopies("orig", to: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("take A", to: pb)
        userCopies("X", to: pb)
        let changeB = keeper.write("take B", to: pb)

        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeA))
        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeB))
        XCTAssertEqual(string(pb), "X")
    }

    func testUserCopyAfterSecondWriteIsKept() {
        let pb = makePasteboard()
        userCopies("orig", to: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("take A", to: pb)
        let changeB = keeper.write("take B", to: pb)
        userCopies("X", to: pb)

        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeA))
        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeB))
        XCTAssertEqual(string(pb), "X")
    }

    func testThreeOverlappingTakes() {
        let pb = makePasteboard()
        userCopies("orig", to: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("take A", to: pb)
        let changeB = keeper.write("take B", to: pb)
        let changeC = keeper.write("take C", to: pb)

        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeA))
        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeB))
        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeC))
        XCTAssertEqual(string(pb), "orig")
    }

    func testFailedSecondTakeKeepsItsTranscript() {
        let pb = makePasteboard()
        userCopies("orig", to: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("take A", to: pb)
        let changeB = keeper.write("transcript B", to: pb)
        keeper.release(changeB)

        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeA))
        XCTAssertEqual(string(pb), "transcript B")
        XCTAssertNil(keeper.pending)

        let changeC = keeper.write("take C", to: pb)
        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeC))
        XCTAssertEqual(string(pb), "transcript B")
    }

    func testReleaseOfOlderChangeIsNoOp() {
        let pb = makePasteboard()
        userCopies("orig", to: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("take A", to: pb)
        let changeB = keeper.write("take B", to: pb)
        keeper.release(changeA)

        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeB))
        XCTAssertEqual(string(pb), "orig")
    }

    func testInheritedSnapshotKeepsAllItems() {
        let pb = makePasteboard()
        pb.clearContents()
        let first = NSPasteboardItem()
        first.setString("hi there", forType: .string)
        let second = NSPasteboardItem()
        second.setData(Data("{\\rtf1 x}".utf8), forType: .rtf)
        second.setData(Data([0, 1, 2, 255]), forType: Self.blobType)
        pb.writeObjects([first, second])
        let original = PasteboardSnapshot.take(from: pb)
        var keeper = ClipboardKeeper()

        let changeA = keeper.write("take A", to: pb)
        let changeB = keeper.write("take B", to: pb)

        XCTAssertFalse(keeper.restore(to: pb, ifChangeCountIs: changeA))
        XCTAssertTrue(keeper.restore(to: pb, ifChangeCountIs: changeB))
        XCTAssertEqual(PasteboardSnapshot.take(from: pb), original)
    }

    /// One event in a generated interleaving. `write(k)` is take k writing, `end(k)` is take k
    /// restoring or releasing, `copy(j)` is the user copying "copy j".
    private enum Event: CustomStringConvertible {
        case write(Int)
        case end(Int)
        case copy(Int)

        var description: String {
            switch self {
            case .write(let k): return "W\(k)"
            case .end(let k): return "E\(k)"
            case .copy(let j): return "U\(j)"
            }
        }
    }

    /// Calls `visit` once for every complete event sequence. Takes write in order 1, 2, 3, may end
    /// in any order after they write, and the user makes exactly `maxCopies` copies at any point.
    private func enumerateSequences(
        takes: Int,
        maxCopies: Int,
        written: Int,
        ended: [Bool],
        copies: Int,
        prefix: [Event],
        visit: ([Event]) -> Void
    ) {
        if written == takes, copies == maxCopies, ended.allSatisfy({ $0 }) {
            visit(prefix)
            return
        }
        if written < takes {
            enumerateSequences(takes: takes, maxCopies: maxCopies, written: written + 1, ended: ended,
                               copies: copies, prefix: prefix + [.write(written + 1)], visit: visit)
        }
        for k in stride(from: 1, through: written, by: 1) where !ended[k - 1] {
            var nextEnded = ended
            nextEnded[k - 1] = true
            enumerateSequences(takes: takes, maxCopies: maxCopies, written: written, ended: nextEnded,
                               copies: copies, prefix: prefix + [.end(k)], visit: visit)
        }
        if copies < maxCopies {
            enumerateSequences(takes: takes, maxCopies: maxCopies, written: written, ended: ended,
                               copies: copies + 1, prefix: prefix + [.copy(copies + 1)], visit: visit)
        }
    }

    func testInvariantOverAllInterleavings() {
        let pb = makePasteboard()
        var runs = 0
        for takes in 1...3 {
            for maxCopies in 0...2 {
                for mask in 0..<(1 << takes) {
                    // Bit k-1 set means take k pasted successfully.
                    let outcomes = (0..<takes).map { mask & (1 << $0) != 0 }
                    enumerateSequences(
                        takes: takes, maxCopies: maxCopies, written: 0,
                        ended: Array(repeating: false, count: takes), copies: 0, prefix: []
                    ) { events in
                        runs += 1
                        let description = events.map(\.description).joined(separator: " ")
                            + " | " + outcomes.map { $0 ? "ok" : "fail" }.joined(separator: ",")

                        userCopies("orig", to: pb)
                        var keeper = ClipboardKeeper()
                        var changes: [Int: Int] = [:]
                        var lastUser = "orig"
                        var lastWriteOrCopy: Event?
                        for event in events {
                            switch event {
                            case .write(let k):
                                changes[k] = keeper.write("take \(k)", to: pb)
                                lastWriteOrCopy = event
                            case .end(let k):
                                let change = changes[k]!
                                if outcomes[k - 1] {
                                    keeper.restore(to: pb, ifChangeCountIs: change)
                                } else {
                                    keeper.release(change)
                                }
                            case .copy(let j):
                                lastUser = "copy \(j)"
                                userCopies(lastUser, to: pb)
                                lastWriteOrCopy = event
                            }
                        }

                        let final = string(pb) ?? ""
                        XCTAssertNil(keeper.pending, description)
                        for k in 1...takes where outcomes[k - 1] {
                            XCTAssertNotEqual(final, "take \(k)", description)
                        }
                        if outcomes.allSatisfy({ $0 }) {
                            XCTAssertEqual(final, lastUser, description)
                        }
                        if case .copy? = lastWriteOrCopy {
                            XCTAssertEqual(final, lastUser, description)
                        } else {
                            let failedTakes = (1...takes).filter { !outcomes[$0 - 1] }.map { "take \($0)" }
                            XCTAssertTrue(final == lastUser || failedTakes.contains(final), description)
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(runs, 500)
    }
}
