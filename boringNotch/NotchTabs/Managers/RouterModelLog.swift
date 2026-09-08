//
//  RouterModelLog.swift
//  boringNotch
//
//  Which models the proxy actually routed to, lately.
//

import Defaults
import Foundation

/// The `model_used` half of the proxy's request log.
///
/// `RouterUsageManager` folds the same file into day/upstream token totals and drops every
/// other field, which is the right shape for "how much did I spend" and useless for "what am
/// I actually being served". A request line carries both:
///
///     {"ts": "...", "upstream": "anthropic", "model_requested": "claude-opus-5",
///      "model_used": "claude-opus-5", "in": 2, "out": 553, ...}
///
/// Read separately rather than bolted onto the usage manager because the two want opposite
/// things from the file. Usage is cumulative and reads only the bytes appended since last
/// time; this is *recent*, so it wants a fixed window off the end and no memory at all —
/// a model dropped from the rotation a week ago should disappear from the column, and an
/// incremental scan could never let it.
@MainActor
final class RouterModelLog: ObservableObject {
    static let shared = RouterModelLog()

    struct Entry: Identifiable, Equatable {
        let upstream: String
        let model: String
        var requests: Int
        var lastSeen: Date?
        var id: String { "\(upstream)/\(model)" }
    }

    /// Most recently used first.
    @Published private(set) var entries: [Entry] = []

    /// The tail actually read. 256 KB is roughly the last two thousand requests at the shape
    /// these lines have, which is days of normal use and still a single read.
    private static let window = 256 * 1024

    private var isReading = false

    private init() {}

    /// Grouped for the panel: upstreams in order of most recent activity, each with its own
    /// models in the same order.
    func byUpstream(upstreams: Int, modelsEach: Int) -> [(upstream: String, models: [Entry])] {
        var order: [String] = []
        var grouped: [String: [Entry]] = [:]
        for entry in entries {
            if grouped[entry.upstream] == nil { order.append(entry.upstream) }
            grouped[entry.upstream, default: []].append(entry)
        }
        return order.prefix(upstreams).map {
            (upstream: $0, models: Array((grouped[$0] ?? []).prefix(modelsEach)))
        }
    }

    /// One shot, off the main thread. There is no timer and nothing to stop: the panel asks
    /// when it appears, and the log only changes when a request is made.
    func refresh() {
        guard !isReading else { return }

        let bookmarkData = Defaults[.routerLogBookmark]
        let bookmark = bookmarkData.isEmpty ? nil : Bookmark(data: bookmarkData)
        let fallback = URL(
            fileURLWithPath: RouterUsageManager.expandingRealTilde(Defaults[.routerLogPath]))

        isReading = true
        Task.detached(priority: .utility) {
            // Same grant the usage manager uses, and it may point at the log or at the folder
            // holding it.
            let granted = bookmark?.resolveURL()
            let didStart = granted?.startAccessingSecurityScopedResource() ?? false
            defer { if didStart, let granted { granted.stopAccessingSecurityScopedResource() } }

            let url = Self.logURL(granted: granted, fallback: fallback)
            let entries = Self.scanTail(url: url)

            await MainActor.run {
                self.isReading = false
                // Only publish a real reading. A failed read means the sandbox grant is
                // missing or the proxy has not run — the panel says so from the usage
                // manager's own flags, and blanking this column as well would just be the
                // same message twice.
                if !entries.isEmpty { self.entries = entries }
            }
        }
    }

    private nonisolated static func logURL(granted: URL?, fallback: URL) -> URL {
        guard let granted else { return fallback }
        let isDirectory = (try? granted.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
        return isDirectory == true ? granted.appendingPathComponent("requests.log") : granted
    }

    private nonisolated static func scanTail(url: URL) -> [Entry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }

        let start = end > UInt64(window) ? end - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return [] }

        // Landing mid-line is the normal case for a tail read, so the first partial line is
        // dropped rather than fed to the parser.
        var slice = data[...]
        if start > 0, let newline = slice.firstIndex(of: UInt8(ascii: "\n")) {
            slice = slice[slice.index(after: newline)...]
        }

        // Built here rather than as a static: a `DateFormatter` shared out of a
        // `@MainActor` type into a detached scan is exactly the kind of cross-actor reference
        // Swift 6 refuses, and building one per scan costs nothing next to the read.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // The proxy writes local wall-clock time with no offset, so no timezone is forced.
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var order: [String] = []
        var found: [String: Entry] = [:]

        for line in slice.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            // `model_used` is what was served; `model_requested` is what was asked for, and
            // they differ whenever the router falls back. What was served is the honest answer
            // to "what am I talking to", so it wins, with the request as the fallback for a
            // line that failed before a model was chosen.
            guard let model = (object["model_used"] as? String)
                ?? (object["model_requested"] as? String), !model.isEmpty
            else { continue }

            let upstream = (object["upstream"] as? String) ?? "unknown"
            let key = "\(upstream)/\(model)"
            let seen = (object["ts"] as? String).flatMap { stamp.date(from: String($0.prefix(19))) }

            if var entry = found[key] {
                entry.requests += 1
                if let seen { entry.lastSeen = seen }
                found[key] = entry
            } else {
                order.append(key)
                found[key] = Entry(upstream: upstream, model: model, requests: 1, lastSeen: seen)
            }
        }

        // The file is append-ordered, so reversing first-seen order gives most-recent-first
        // without needing every line to carry a parseable timestamp.
        return order.reversed().compactMap { found[$0] }
    }

    /// `anthropic/claude-sonnet-5` and `z-ai/glm-5.3` are both too wide for a notch column and
    /// both mostly prefix. The vendor is already the column's own grouping, so it goes.
    static func short(_ model: String) -> String {
        var name = model
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        for prefix in ["claude-", "anthropic.", "models/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name.count > 18 ? String(name.prefix(17)) + "…" : name
    }
}
