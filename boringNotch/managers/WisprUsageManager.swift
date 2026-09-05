//
//  WisprUsageManager.swift
//  boringNotch
//
//  Words dictated through Wispr Flow, counted from its own local database.
//

import AppKit
import Defaults
import Foundation
import SQLite3

/// Counts what has been dictated, so the usage strip covers the input side of the day's
/// work rather than only what was spent generating tokens.
///
/// **This one has to accumulate, and that is not an optimisation.** Wispr Flow uploads its
/// transcripts and prunes what it has already synced: the local `History` table was holding
/// nine rows spanning two hours when this was written, with everything older gone. Reading
/// it the way `RouterUsageManager` reads the request log — scan what is there, report the
/// window — would make "7 DAYS" a label on two hours of data. So every read folds new rows
/// into a per-day tally this app keeps itself, and the window is taken from that. The
/// figure is therefore honest but *forward-looking*: it counts from the day this was
/// installed, not from the day Wispr Flow was.
///
/// Rows are consumed by a timestamp watermark, held sixty seconds back from now. A
/// dictation lands in the table before `numWords` is filled in, so consuming right up to
/// the present would bank a row at zero and never look at it again.
@MainActor
final class WisprUsageManager: ObservableObject {
    static let shared = WisprUsageManager()

    /// Day (yyyy-MM-dd, local) → words dictated. Persisted, because the source prunes.
    @Published private(set) var wordsByDay: [String: Int] = Defaults[.wisprWordsByDay]
    @Published private(set) var isAvailable = false
    @Published private(set) var needsAuthorization = false

    private var isReading = false

    /// Anything older than the longest window the strip can ask for is dead weight.
    private static let retainedDays = 30

    private init() {}

    // MARK: - Windows

    func words(for window: UsageWindow) -> Int {
        guard let count = window.days else { return wordsByDay.values.reduce(0, +) }
        let calendar = Calendar.current
        let today = Date()
        return (0..<count).reduce(0) { total, offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return total
            }
            return total + (wordsByDay[Self.dayFormatter.string(from: day)] ?? 0)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Reading

    func refresh() {
        guard !isReading else { return }

        let bookmarkData = Defaults[.wisprDatabaseBookmark]
        let bookmark = bookmarkData.isEmpty ? nil : Bookmark(data: bookmarkData)
        let fallback = URL(fileURLWithPath: Self.expandingRealTilde(Defaults[.wisprDatabasePath]))
        let watermark = Defaults[.wisprLastSeen]
        let carried = wordsByDay

        isReading = true
        Task.detached(priority: .utility) {
            let granted = bookmark?.resolveURL()
            let didStart = granted?.startAccessingSecurityScopedResource() ?? false
            defer { if didStart, let granted { granted.stopAccessingSecurityScopedResource() } }

            let databaseURL = Self.databaseURL(granted: granted, fallback: fallback)
            let scanned = Self.scan(url: databaseURL, since: watermark, into: carried)

            await MainActor.run {
                self.isReading = false
                switch scanned {
                case .success(let result):
                    self.isAvailable = true
                    self.needsAuthorization = false
                    self.wordsByDay = Self.pruned(result.words)
                    Defaults[.wisprWordsByDay] = self.wordsByDay
                    Defaults[.wisprLastSeen] = result.watermark
                    Defaults[.wisprDiagnostic] =
                        "ok — \(self.words(for: .today)) words today, "
                        + "\(self.words(for: .week)) this week"
                case .failure(let error):
                    self.isAvailable = !self.wordsByDay.isEmpty
                    // Same ambiguity as the request log: without a grant the sandbox
                    // refuses metadata reads too, so "missing" and "denied" are
                    // indistinguishable and have the same fix.
                    self.needsAuthorization = bookmarkData.isEmpty
                    Defaults[.wisprDiagnostic] =
                        "failed at \(databaseURL.path) — \((error as NSError).localizedDescription)"
                }
            }
        }
    }

    private nonisolated static func databaseURL(granted: URL?, fallback: URL) -> URL {
        guard let granted else { return fallback }
        let isDirectory = (try? granted.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
        return isDirectory == true ? granted.appendingPathComponent("flow.sqlite") : granted
    }

    private nonisolated static func pruned(_ words: [String: Int]) -> [String: Int] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -retainedDays, to: Date())
        guard let cutoff else { return words }
        let earliest = dayFormatter.string(from: cutoff)
        return words.filter { $0.key >= earliest }
    }

    // MARK: - SQLite

    /// Opened read-only, against the live file rather than a copy.
    ///
    /// Wispr Flow keeps the database in WAL mode and writes to it while this reads, which
    /// is precisely what WAL is for — a reader sees a consistent snapshot and takes no
    /// lock the writer has to wait on. `mode=ro` is on the URI rather than a plain
    /// `SQLITE_OPEN_READONLY` so that the setting survives into any attached journal.
    private nonisolated static func scan(
        url: URL,
        since watermark: String,
        into carried: [String: Int]
    ) -> Result<(words: [String: Int], watermark: String), Error> {
        var handle: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro"

        let opened = sqlite3_open_v2(
            uri, &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX,
            nil)
        defer { sqlite3_close(handle) }

        guard opened == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            return .failure(NSError(
                domain: "WisprUsage", code: Int(opened),
                userInfo: [NSLocalizedDescriptionKey: message]))
        }

        // Bucketed by local day inside SQLite, which parses the ' +00:00' offset Wispr
        // writes and converts it correctly — doing it in Swift would mean parsing every
        // row's timestamp twice. The sixty-second holdback keeps a dictation that has
        // landed but not yet been counted out of the tally until it settles.
        let sql = """
            SELECT date(timestamp, 'localtime') AS day, SUM(numWords), MAX(timestamp)
            FROM History
            WHERE numWords > 0
              AND timestamp > ?
              AND timestamp < strftime('%Y-%m-%d %H:%M:%f +00:00', 'now', '-60 seconds')
            GROUP BY day
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failure(NSError(
                domain: "WisprUsage", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))]))
        }

        // SQLITE_TRANSIENT: SQLite must copy the string, because this Swift buffer is gone
        // by the time the statement runs.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, watermark, -1, transient)

        var words = carried
        var newWatermark = watermark

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let dayText = sqlite3_column_text(statement, 0) else { continue }
            let day = String(cString: dayText)
            let count = Int(sqlite3_column_int64(statement, 1))
            words[day, default: 0] += count

            if let maxText = sqlite3_column_text(statement, 2) {
                let seen = String(cString: maxText)
                if seen > newWatermark { newWatermark = seen }
            }
        }

        return .success((words, newWatermark))
    }

    // MARK: - Granting

    /// Asks for the folder rather than the file: SQLite needs to read the `-wal` and
    /// `-shm` sidecars beside `flow.sqlite` to see anything written since the last
    /// checkpoint, and a file grant covers neither.
    func requestAccess() {
        let configured = URL(fileURLWithPath: Self.expandingRealTilde(Defaults[.wisprDatabasePath]))

        let panel = NSOpenPanel()
        panel.title = "Choose the Wispr Flow folder"
        panel.message = "Pick the folder holding flow.sqlite. Choosing the folder rather "
            + "than the file also picks up the -wal file beside it, which is where "
            + "anything dictated since the last checkpoint actually lives."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = configured.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let bookmark = try? Bookmark(url: url) {
            Defaults[.wisprDatabaseBookmark] = bookmark.data
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            Defaults[.wisprDatabasePath] = isDirectory == true
                ? url.appendingPathComponent("flow.sqlite").path
                : url.path
            refresh()
        }
    }

    /// Shares `RouterUsageManager`'s tilde handling for the same reason: a sandboxed
    /// `NSHomeDirectory()` points inside the container, not at the real home.
    private static func expandingRealTilde(_ path: String) -> String {
        RouterUsageManager.expandingRealTilde(path)
    }
}
