//
//  RouterUsageManager.swift
//  boringNotch
//
//  Today's API usage, read from the local Switchboard request log.
//

import AppKit
import Combine
import Defaults
import Foundation

struct RouterUsageTotals: Equatable {
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var cost: Double = 0

    /// Tokens that were actually generated or newly read, excluding cache hits.
    var billedTokens: Int { inputTokens + outputTokens }
    var allTokens: Int { inputTokens + outputTokens + cachedTokens }
}

/// Reads API usage out of Switchboard's request log rather than polling any vendor.
///
/// Switchboard is the local multi-provider proxy that Claude Code and friends route
/// through, and it already appends one JSON object per request:
///
///     {"ts": "2026-09-04T13:41:57", "upstream": "openrouter", "model_used": "z-ai/glm-5.3",
///      "in": 14, "out": 20, "cache_read": 0, "cost": 0.0001076}
///
/// Reading that beats polling vendor APIs on every axis that matters here. No keys live in
/// the app — which counts double, because this app is GPL-3.0 and any build handed to
/// anyone ships its source, so a key pasted in is a key published. No network call, no auth
/// to expire, no per-vendor rate limit. And every provider is covered at once: adding one
/// to Switchboard adds it here for free.
///
/// The tradeoff is coverage, and it is worth being honest about. This is exactly "what went
/// through the proxy". Traffic that bypasses it — claude.ai in a browser, an app calling a
/// vendor directly — is invisible here, which is why the strip labels the figure rather
/// than presenting it as a total bill. Subscription rows also carry no `cost`, because plan
/// quota is not dollars; those show as tokens only.
@MainActor
final class RouterUsageManager: ObservableObject {
    static let shared = RouterUsageManager()

    @Published private(set) var totalsByUpstream: [String: RouterUsageTotals] = [:]
    /// False when the log cannot be read. `needsAuthorization` separates the two reasons:
    /// the sandbox has not been granted access yet (fixable by the user, so say so), or
    /// the file genuinely is not there.
    @Published private(set) var isAvailable = false
    @Published private(set) var needsAuthorization = false

    var combined: RouterUsageTotals {
        totalsByUpstream.values.reduce(into: RouterUsageTotals()) { sum, totals in
            sum.requests += totals.requests
            sum.inputTokens += totals.inputTokens
            sum.outputTokens += totals.outputTokens
            sum.cachedTokens += totals.cachedTokens
            sum.cost += totals.cost
        }
    }

    private var byteOffset: UInt64 = 0
    private var loadedDay = ""
    private var isReading = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {}

    /// Called when the strip appears. Parses only the bytes appended since last time, so
    /// the repeat cost is a few hundred microseconds even though the log grows all day.
    func refresh() {
        guard !isReading else { return }

        let today = Self.dayFormatter.string(from: Date())
        let isNewDay = today != loadedDay

        // This app ships with com.apple.security.app-sandbox, so a path outside the
        // container cannot be opened however correct it is — which is why a perfectly
        // present log first read as "no router log". Access comes from a security-scoped
        // bookmark the user grants once, the same machinery the Shelf uses for dropped
        // files. The raw path is still tried as a fallback so an unsandboxed build works.
        let bookmarkData = Defaults[.routerLogBookmark]
        let bookmark = bookmarkData.isEmpty ? nil : Bookmark(data: bookmarkData)
        let fallbackURL = URL(
            fileURLWithPath: NSString(string: Defaults[.routerLogPath]).expandingTildeInPath)

        // A day rollover invalidates the running totals, so rescan from the top to pick up
        // whatever landed after midnight.
        let startOffset = isNewDay ? 0 : byteOffset
        let carried = isNewDay ? [:] : totalsByUpstream

        isReading = true
        Task.detached(priority: .utility) {
            let scanned: (totals: [String: RouterUsageTotals], offset: UInt64)?
            if let url = bookmark?.resolveURL() {
                // Explicit start/stop rather than Bookmark.withAccess: inside an async
                // context Swift resolves that overload to the async variant and then
                // demands an `await` for a body that is entirely synchronous.
                let didStart = url.startAccessingSecurityScopedResource()
                scanned = Self.scan(url: url, from: startOffset, day: today, into: carried)
                if didStart { url.stopAccessingSecurityScopedResource() }
            } else {
                scanned = Self.scan(url: fallbackURL, from: startOffset, day: today, into: carried)
            }

            await MainActor.run {
                self.isReading = false
                guard let scanned else {
                    self.isAvailable = false
                    // With no bookmark there is no way to tell "file missing" from
                    // "sandbox denied" — the sandbox refuses metadata reads too, so
                    // fileExists() lies here. Either way the fix is the same: pick the
                    // file. Only once a bookmark exists and still fails is it genuinely
                    // gone or moved.
                    self.needsAuthorization = bookmarkData.isEmpty
                    return
                }
                self.isAvailable = true
                self.needsAuthorization = false
                self.loadedDay = today
                self.byteOffset = scanned.offset
                self.totalsByUpstream = scanned.totals
            }
        }
    }

    /// One-time grant. Opens on the configured log's folder with hidden files shown,
    /// because the default location is under `~/.local` and an open panel hides that.
    @MainActor
    func requestAccess() {
        let configured = URL(
            fileURLWithPath: NSString(string: Defaults[.routerLogPath]).expandingTildeInPath)

        let panel = NSOpenPanel()
        panel.title = "Choose the request log"
        panel.message = "Pick the proxy's requests.log so the notch can read today's API usage."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = configured.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let bookmark = try? Bookmark(url: url) {
            Defaults[.routerLogBookmark] = bookmark.data
            Defaults[.routerLogPath] = url.path
            // The grant invalidates whatever was counted before it.
            byteOffset = 0
            loadedDay = ""
            totalsByUpstream = [:]
            refresh()
        }
    }

    /// Returns nil only when the log cannot be opened at all.
    private nonisolated static func scan(
        url: URL,
        from start: UInt64,
        day: String,
        into carried: [String: RouterUsageTotals]
    ) -> (totals: [String: RouterUsageTotals], offset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }

        // Rotated or truncated under us — start over rather than reading from a stale
        // offset into the middle of a line.
        var start = start
        if end < start { start = 0 }
        guard end > start else { return (carried, end) }

        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return (carried, start) }

        // Whole lines only. A partial trailing line means the proxy is mid-write, so leave
        // the offset short of it and pick it up complete on the next refresh.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return (carried, start) }
        let consumed = start + UInt64(lastNewline) + 1

        var totals = carried
        for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestamp = object["ts"] as? String,
                  timestamp.hasPrefix(day)
            else { continue }

            let upstream = (object["upstream"] as? String) ?? "unknown"
            var entry = totals[upstream] ?? RouterUsageTotals()
            entry.requests += 1
            entry.inputTokens += (object["in"] as? Int) ?? 0
            entry.outputTokens += (object["out"] as? Int) ?? 0
            entry.cachedTokens += ((object["cache_read"] as? Int) ?? 0)
                + ((object["cache_write"] as? Int) ?? 0)
            entry.cost += (object["cost"] as? Double) ?? 0
            totals[upstream] = entry
        }

        return (totals, consumed)
    }
}
