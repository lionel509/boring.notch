//
//  RouterUsageManager.swift
//  boringNotch
//
//  API usage and subscription limits, read from local files the proxy and the statusline
//  already write.
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

    static func += (lhs: inout RouterUsageTotals, rhs: RouterUsageTotals) {
        lhs.requests += rhs.requests
        lhs.inputTokens += rhs.inputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.cachedTokens += rhs.cachedTokens
        lhs.cost += rhs.cost
    }
}

enum UsageWindow: String, CaseIterable {
    case today, week, month, all

    var label: String {
        switch self {
        case .today: "TODAY"
        case .week: "WEEK"
        case .month: "MONTH"
        case .all: "ALL TIME"
        }
    }

    /// Days back from today, inclusive. Nil means everything on record.
    var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

/// What the subscription's own meters say, as opposed to what was spent.
struct SubscriptionLimits: Equatable {
    var fiveHourPercent: Double
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Double
    var sevenDayResetsAt: Date?
    var updatedAt: Date?
}

/// Reads API usage out of the proxy's request log rather than polling any vendor.
///
/// The proxy appends one JSON object per request:
///
///     {"ts": "2026-09-04T13:41:57", "upstream": "openrouter", "model_used": "z-ai/glm-5.3",
///      "in": 14, "out": 20, "cache_read": 0, "cost": 0.0001076}
///
/// Reading that beats polling vendor APIs on every axis that matters here. No keys live in
/// the app — which counts double, because this app is GPL-3.0 and any build handed to
/// anyone ships its source, so a key pasted in is a key published. No network call, no auth
/// to expire, no per-vendor rate limit. And every provider is covered at once: adding one
/// to the proxy adds it here for free.
///
/// The tradeoff is coverage, and it is worth being honest about. This is exactly "what went
/// through the proxy". Traffic that bypasses it — a browser session, an app calling a
/// vendor directly — is invisible here, which is why the strip labels the figure rather
/// than presenting it as a total bill. Subscription rows also carry no `cost`, because plan
/// quota is not dollars; those show as tokens only, and the quota itself comes from
/// `rate-limits.json` instead.
@MainActor
final class RouterUsageManager: ObservableObject {
    static let shared = RouterUsageManager()

    /// Day (yyyy-MM-dd) → upstream → totals. Bucketing by day up front means every window
    /// is a fold over the same scan, and a midnight rollover needs no special handling.
    @Published private(set) var totalsByDay: [String: [String: RouterUsageTotals]] = [:]
    @Published private(set) var limits: SubscriptionLimits?
    @Published private(set) var isAvailable = false
    @Published private(set) var needsAuthorization = false

    private var byteOffset: UInt64 = 0
    private var isReading = false

    // MARK: - Windows

    func totals(for window: UsageWindow) -> RouterUsageTotals {
        byUpstream(for: window).values.reduce(into: RouterUsageTotals()) { $0 += $1 }
    }

    func byUpstream(for window: UsageWindow) -> [String: RouterUsageTotals] {
        var result: [String: RouterUsageTotals] = [:]
        for day in days(in: window) {
            for (upstream, totals) in totalsByDay[day] ?? [:] {
                result[upstream, default: RouterUsageTotals()] += totals
            }
        }
        return result
    }

    private func days(in window: UsageWindow) -> [String] {
        guard let count = window.days else { return Array(totalsByDay.keys) }
        let calendar = Calendar.current
        let today = Date()
        return (0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map(Self.dayFormatter.string(from:))
        }
    }

    // MARK: - Paths

    /// Expands a leading `~` against the *real* home directory.
    ///
    /// `expandingTildeInPath` and `NSHomeDirectory()` both resolve to the sandbox container
    /// when the app is sandboxed, so `~/.local/share/…` silently became
    /// `~/Library/Containers/theboringteam.boringnotch/Data/.local/share/…` — a path that
    /// does not exist, then reported as though the sandbox had denied a real file. The
    /// password database is not redirected, so it still knows where home actually is.
    static func expandingRealTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }

        let home: String = {
            if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
                return String(cString: directory)
            }
            return NSHomeDirectory()
        }()

        return home + String(path.dropFirst(1))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {}

    // MARK: - Reading

    /// Parses only the bytes appended since last time, so the repeat cost stays in the
    /// hundreds of microseconds however large the log grows.
    func refresh() {
        guard !isReading else { return }

        let bookmarkData = Defaults[.routerLogBookmark]
        let bookmark = bookmarkData.isEmpty ? nil : Bookmark(data: bookmarkData)
        let fallback = URL(fileURLWithPath: Self.expandingRealTilde(Defaults[.routerLogPath]))
        let startOffset = byteOffset
        let carried = totalsByDay

        isReading = true
        Task.detached(priority: .utility) {
            // The grant may be for the log itself or for the folder holding it. A folder
            // is preferred, because rate-limits.json lives beside the log and one grant
            // then covers both; a file grant still works, it just cannot see the limits.
            let granted = bookmark?.resolveURL()
            let didStart = granted?.startAccessingSecurityScopedResource() ?? false
            defer { if didStart, let granted { granted.stopAccessingSecurityScopedResource() } }

            let logURL = Self.logURL(granted: granted, fallback: fallback)
            let scanned = Self.scan(url: logURL, from: startOffset, into: carried)
            let limits = Self.readLimits(beside: logURL)

            await MainActor.run {
                self.isReading = false
                self.limits = limits

                switch scanned {
                case .success(let result):
                    self.isAvailable = true
                    self.needsAuthorization = false
                    self.byteOffset = result.offset
                    self.totalsByDay = result.totals
                    let today = self.totals(for: .today)
                    Defaults[.routerLogDiagnostic] =
                        "ok — \(today.requests) requests, \(today.billedTokens) billed tokens today"
                            + (limits == nil ? " (no rate-limits.json — grant the folder, not the file)" : "")
                case .failure(let error):
                    self.isAvailable = false
                    // With no bookmark there is no telling "file missing" from "sandbox
                    // denied" — the sandbox refuses metadata reads too, so fileExists()
                    // lies. Either way the fix is the same: pick the folder.
                    self.needsAuthorization = bookmarkData.isEmpty
                    Defaults[.routerLogDiagnostic] =
                        "failed at \(logURL.path) — \((error as NSError).localizedDescription)"
                }
            }
        }
    }

    private nonisolated static func logURL(granted: URL?, fallback: URL) -> URL {
        guard let granted else { return fallback }
        let isDirectory = (try? granted.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
        return isDirectory == true ? granted.appendingPathComponent("requests.log") : granted
    }

    private nonisolated static func readLimits(beside log: URL) -> SubscriptionLimits? {
        let url = log.deletingLastPathComponent().appendingPathComponent("rate-limits.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let iso = ISO8601DateFormatter()
        func date(_ key: String) -> Date? {
            (object[key] as? String).flatMap(iso.date(from:))
        }

        return SubscriptionLimits(
            fiveHourPercent: (object["five_hour_pct"] as? Double) ?? 0,
            fiveHourResetsAt: date("five_hour_resets_at"),
            sevenDayPercent: (object["seven_day_pct"] as? Double) ?? 0,
            sevenDayResetsAt: date("seven_day_resets_at"),
            updatedAt: date("ts"))
    }

    /// Surfaces the real error rather than collapsing every failure to nil — "operation not
    /// permitted" and "no such file" call for completely different fixes, and guessing
    /// between them sent this down a wrong path once already.
    private nonisolated static func scan(
        url: URL,
        from start: UInt64,
        into carried: [String: [String: RouterUsageTotals]]
    ) -> Result<(totals: [String: [String: RouterUsageTotals]], offset: UInt64), Error> {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return .failure(error)
        }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else {
            return .failure(CocoaError(.fileReadUnknown))
        }

        // Rotated or truncated under us — start over rather than reading from a stale
        // offset into the middle of a line.
        var start = start
        if end < start { start = 0 }
        guard end > start else { return .success((carried, end)) }

        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return .success((carried, start)) }

        // Whole lines only. A partial trailing line means the proxy is mid-write, so leave
        // the offset short of it and pick it up complete on the next refresh.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return .success((carried, start))
        }
        let consumed = start + UInt64(lastNewline) + 1

        var totals = carried
        for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestamp = object["ts"] as? String,
                  timestamp.count >= 10
            else { continue }

            let day = String(timestamp.prefix(10))
            let upstream = (object["upstream"] as? String) ?? "unknown"

            var entry = totals[day]?[upstream] ?? RouterUsageTotals()
            entry.requests += 1
            entry.inputTokens += (object["in"] as? Int) ?? 0
            entry.outputTokens += (object["out"] as? Int) ?? 0
            entry.cachedTokens += ((object["cache_read"] as? Int) ?? 0)
                + ((object["cache_write"] as? Int) ?? 0)
            entry.cost += (object["cost"] as? Double) ?? 0
            totals[day, default: [:]][upstream] = entry
        }

        return .success((totals, consumed))
    }

    // MARK: - Granting

    /// One-time grant. Asks for the *folder* rather than the log file: `rate-limits.json`
    /// sits beside it, and a folder grant covers both. Opens on the configured location
    /// with hidden files shown, because the default lives under `~/.local`.
    @MainActor
    func requestAccess() {
        let configured = URL(fileURLWithPath: Self.expandingRealTilde(Defaults[.routerLogPath]))

        let panel = NSOpenPanel()
        panel.title = "Choose the proxy folder"
        panel.message = "Pick the folder holding requests.log. Choosing the folder rather "
            + "than the file also picks up rate-limits.json beside it, which carries the "
            + "5-hour and 7-day subscription meters."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = configured.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let bookmark = try? Bookmark(url: url) {
            Defaults[.routerLogBookmark] = bookmark.data
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            Defaults[.routerLogPath] = isDirectory == true
                ? url.appendingPathComponent("requests.log").path
                : url.path
            // The grant invalidates whatever was counted before it.
            byteOffset = 0
            totalsByDay = [:]
            refresh()
        }
    }
}
