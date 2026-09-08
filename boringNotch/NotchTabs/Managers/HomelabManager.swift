//
//  HomelabManager.swift
//  boringNotch
//
//  Prometheus and Loki, reduced to the handful of figures a 578x150 panel can show.
//

import Combine
import Defaults
import Foundation

/// What a visible panel needs. Kept separate so the Alerts panel does not pay for node
/// metrics and the Fleet panel does not pay for log lines: the tick fetches the union of
/// whatever is actually on screen, and nothing at all when the notch is shut.
enum HomelabFeed: Hashable { case nodes, alerts }

/// Whether a source is configured, being probed, answering, or broken. Panels need all four
/// to draw an honest state — "no URL set" and "the box is down" are different problems and
/// deserve different words.
enum HomelabSource: Equatable { case unset, probing, ok, failed(String) }

/// Polls Prometheus and Loki over plain HTTP, on the same discipline as `SystemStatsManager`:
/// a reference-counted `start()`/`stop()`, one stored `Timer`, invalidated at zero watchers.
///
/// The address is never baked in. This is a fork of a GPL app, so any build handed to anyone
/// ships its source — a literal `192.168.x` in it is somebody else's bug report. Both URLs
/// come from `Defaults`, and an empty one is a designed empty state rather than a failed
/// request.
@MainActor
final class HomelabManager: ObservableObject {
    static let shared = HomelabManager()

    struct NodeStats: Equatable {
        var up: Bool?
        var cpu: Double?
        var memory: Double?
        var load1: Double?
        var rootUsed: Double?
        var volumeSize: Double?
        var volumeAvail: Double?
    }

    /// Per-host log activity. `lines` is the liveness signal for the guests with no
    /// node_exporter — a box that is still journalling is a box that is still up.
    struct HostLog: Equatable {
        var lines: Int = 0
        var critical: Int = 0
        var warning: Int = 0
    }

    struct AlertLine: Identifiable, Equatable {
        let id: String
        let date: Date
        let level: String
        let host: String
        let text: String
        var isCritical: Bool { level == "CRITICAL" }
    }

    @Published private(set) var nodes: [String: NodeStats] = [:]
    @Published private(set) var hosts: [String: HostLog] = [:]
    @Published private(set) var alerts: [AlertLine] = []
    /// The vpn-watchdog's own verdict on whether traffic is leaving through the tunnel.
    @Published private(set) var vpnExit: AlertLine?
    @Published private(set) var prometheus: HomelabSource = .unset
    @Published private(set) var loki: HomelabSource = .unset
    @Published private(set) var lastUpdated: Date?
    /// Per-feed, not one shared flag. `lastUpdated` moves whenever *any* panel polls, so a
    /// panel that has never run its own query would otherwise skip straight past its probing
    /// state and claim, on another panel's timestamp, that it found nothing.
    @Published private(set) var nodesLoaded = false
    @Published private(set) var alertsLoaded = false

    /// Ten seconds, never faster. Nothing here moves at 1 Hz, and every tick is three
    /// round trips over Wi-Fi — by far the most expensive thing any panel does.
    private static let interval: TimeInterval = 10
    /// Just under the tick, so an extra `refresh()` from a panel appearing mid-cycle is
    /// answered from what is already on screen instead of re-querying.
    private static let cacheLifetime: TimeInterval = 9
    /// A dead homelab must not hold the poller for the URLSession default of sixty seconds.
    static let timeout: TimeInterval = 6
    /// How recently a host must have logged to count as alive.
    static let livenessWindowMinutes = 15
    /// One window for both the Fleet panel's per-host counts and the Alerts panel's list,
    /// so a "0C 0W" on one screen can never contradict a warning shown on the other.
    static let alertWindowHours = 24

    private var timer: Timer?
    private var feeds: [HomelabFeed: Int] = [:]
    private var isFetching = false

    private init() {}

    // MARK: - Lifecycle

    func start(_ feed: HomelabFeed) {
        feeds[feed, default: 0] += 1
        if timer == nil {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        // Forced: a panel that just flipped into view would otherwise sit on another
        // panel's cached answer, which does not contain its feed at all.
        refresh(force: true)
    }

    func stop(_ feed: HomelabFeed) {
        feeds[feed] = max(0, (feeds[feed] ?? 0) - 1)
        guard feeds.values.reduce(0, +) == 0 else { return }
        timer?.invalidate()
        timer = nil
        // Readings deliberately survive. Coming back to a panel showing the last real
        // figures beats coming back to a spinner for something measured ten seconds ago.
    }

    private var wantsNodes: Bool { (feeds[.nodes] ?? 0) > 0 }
    private var wantsAlerts: Bool { (feeds[.alerts] ?? 0) > 0 }

    // MARK: - Refresh

    func refresh(force: Bool = false) {
        guard !isFetching else { return }
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.cacheLifetime {
            return
        }

        let prom = Self.base(Defaults[.homelabPrometheusURL])
        let logs = Self.base(Defaults[.homelabLokiURL])
        if prom == nil { prometheus = .unset }
        if logs == nil { loki = .unset }
        guard prom != nil || logs != nil else { return }
        if prom != nil, prometheus == .unset { prometheus = .probing }
        if logs != nil, loki == .unset { loki = .probing }

        isFetching = true
        Task {
            defer { isFetching = false }
            if let prom, wantsNodes { await loadNodes(from: prom) }
            if let logs {
                if wantsNodes { await loadHosts(from: logs) }
                if wantsAlerts { await loadAlerts(from: logs) }
            }
            lastUpdated = Date()
        }
    }

    /// One request for every node figure. Each sub-expression is stamped with a `kind`
    /// label and unioned, so five metrics across every scraped instance cost a single
    /// round trip instead of five — which on Wi-Fi is the whole cost.
    private var nodeQuery: String {
        let volumes = "{instance=\"\(NASHost.label)\", mountpoint=~\"/volume[0-9]+|/\"}"
        return """
        label_replace(1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])), "kind", "cpu", "", "")
        or label_replace(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes), "kind", "mem", "", "")
        or label_replace(node_load1, "kind", "load", "", "")
        or label_replace(1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}), "kind", "fs", "", "")
        or label_replace(up, "kind", "up", "", "")
        or label_replace(sum by (instance) (node_filesystem_size_bytes\(volumes)), "kind", "volSize", "", "")
        or label_replace(sum by (instance) (node_filesystem_avail_bytes\(volumes)), "kind", "volAvail", "", "")
        """
    }

    private func loadNodes(from base: URL) async {
        var components = URLComponents(url: base.appendingPathComponent("api/v1/query"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: nodeQuery)]
        do {
            let samples = try await vector(at: components, key: "metric")
            var built: [String: NodeStats] = [:]
            for sample in samples {
                guard let instance = sample.labels["instance"] else { continue }
                var stats = built[instance] ?? NodeStats()
                switch sample.labels["kind"] {
                case "cpu": stats.cpu = sample.value
                case "mem": stats.memory = sample.value
                case "load": stats.load1 = sample.value
                case "fs": stats.rootUsed = sample.value
                case "up": stats.up = sample.value >= 1
                case "volSize": stats.volumeSize = sample.value
                case "volAvail": stats.volumeAvail = sample.value
                default: break
                }
                built[instance] = stats
            }
            if built != nodes { nodes = built }
            nodesLoaded = true
            prometheus = .ok
        } catch {
            prometheus = .failed(Self.reason(error))
        }
    }

    private func loadHosts(from base: URL) async {
        let liveness = "sum by (host) (count_over_time({job=~\".+\"}[\(Self.livenessWindowMinutes)m]))"
        let levels = "sum by (host, level) (count_over_time({level=~\"CRITICAL|WARN\"}[\(Self.alertWindowHours)h]))"
        do {
            var built: [String: HostLog] = [:]
            for sample in try await lokiVector(base, liveness) {
                guard let host = sample.labels["host"] else { continue }
                built[host, default: HostLog()].lines = Int(sample.value)
            }
            for sample in try await lokiVector(base, levels) {
                guard let host = sample.labels["host"] else { continue }
                if sample.labels["level"] == "CRITICAL" {
                    built[host, default: HostLog()].critical = Int(sample.value)
                } else {
                    built[host, default: HostLog()].warning = Int(sample.value)
                }
            }
            if built != hosts { hosts = built }
            nodesLoaded = true
            loki = .ok
        } catch {
            loki = .failed(Self.reason(error))
        }
    }

    private func loadAlerts(from base: URL) async {
        do {
            let recent = try await streams(base, "{level=~\"CRITICAL|WARN\"}", limit: 12,
                                           hours: Self.alertWindowHours)
            if recent != alerts { alerts = recent }
            let exit = try await streams(base, "{job=\"vpn-watchdog\", check=\"exit_ip\"}",
                                         limit: 1, hours: 6).first
            if exit != vpnExit { vpnExit = exit }
            alertsLoaded = true
            loki = .ok
        } catch {
            loki = .failed(Self.reason(error))
        }
    }
}
