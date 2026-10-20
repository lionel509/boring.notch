import AppKit

/// Everything on a pasteboard, as (type, bytes) per item, so it can be put back exactly,
/// with each item's types kept in their original order.
struct PasteboardSnapshot: Equatable {
    /// One dictionary per NSPasteboardItem. Types whose data reads nil are skipped.
    let items: [[NSPasteboard.PasteboardType: Data]]
    /// The kept types of each item, in pasteboard order. Apps that take the first type they can
    /// read depend on this order, so restore writes the types back in it.
    let types: [[NSPasteboard.PasteboardType]]

    static func take(from pb: NSPasteboard) -> PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var types: [[NSPasteboard.PasteboardType]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            var order: [NSPasteboard.PasteboardType] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                    order.append(type)
                }
            }
            items.append(dict)
            types.append(order)
        }
        return PasteboardSnapshot(items: items, types: types)
    }

    /// Replaces the pasteboard contents with `text` and returns the changeCount after the write.
    @discardableResult
    static func write(_ text: String, to pb: NSPasteboard) -> Int {
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb.changeCount
    }

    /// Puts the snapshot back, but only if nobody else changed the pasteboard since `write`.
    /// Returns false and touches nothing when the changeCount moved.
    @discardableResult
    func restore(to pb: NSPasteboard, ifChangeCountIs expected: Int) -> Bool {
        guard pb.changeCount == expected else { return false }
        pb.clearContents()
        let restored: [NSPasteboardItem] = zip(items, types).map { dict, order in
            let item = NSPasteboardItem()
            for type in order {
                if let data = dict[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        if !restored.isEmpty {
            pb.writeObjects(restored)
        }
        return true
    }
}

/// Owns the one pending clipboard restore across overlapping takes. A take that writes while an
/// earlier take's transcript is still on the pasteboard inherits that take's snapshot, and restores
/// are guarded by changeCount, so a real user copy is never overwritten.
struct ClipboardKeeper {
    struct Pending: Equatable {
        let snapshot: PasteboardSnapshot
        let change: Int
    }

    private(set) var pending: Pending?

    init() {}

    /// Writes `text` and returns its changeCount. Keeps the user's original snapshot when the
    /// pasteboard still holds an earlier take's transcript, so the restore brings back the original.
    @discardableResult
    mutating func write(_ text: String, to pb: NSPasteboard) -> Int {
        let original: PasteboardSnapshot
        if let pending, pb.changeCount == pending.change {
            original = pending.snapshot
        } else {
            original = PasteboardSnapshot.take(from: pb)
        }
        let change = PasteboardSnapshot.write(text, to: pb)
        pending = Pending(snapshot: original, change: change)
        return change
    }

    /// Restores the pending snapshot if `change` is still the pending take and nobody copied since.
    /// Returns false and touches nothing when a newer take owns the restore.
    @discardableResult
    mutating func restore(to pb: NSPasteboard, ifChangeCountIs change: Int) -> Bool {
        guard let owned = pending, owned.change == change else { return false }
        pending = nil
        return owned.snapshot.restore(to: pb, ifChangeCountIs: change)
    }

    /// Drops the pending restore when the take with `change` failed, so its transcript stays on the clipboard.
    mutating func release(_ change: Int) {
        if pending?.change == change {
            pending = nil
        }
    }
}
