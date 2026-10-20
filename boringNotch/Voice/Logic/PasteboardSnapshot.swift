import AppKit

/// Everything on a pasteboard, as (type, bytes) per item, so it can be put back exactly.
struct PasteboardSnapshot: Equatable {
    /// One dictionary per NSPasteboardItem. Types whose data reads nil are skipped.
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func take(from pb: NSPasteboard) -> PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
        return PasteboardSnapshot(items: items)
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
        let restored: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pb.writeObjects(restored)
        }
        return true
    }
}
