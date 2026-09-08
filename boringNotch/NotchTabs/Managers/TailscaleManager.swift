//
//  TailscaleManager.swift
//  boringNotch
//
//  Tailnet state, read through the XPC helper.
//

import Defaults
import SwiftUI

/// Reads `tailscale status --json`.
///
/// Two things shape this class. The app is sandboxed, so it cannot run the CLI itself — the
/// call goes through `XPCHelperClient`, which is not. And the call is **expensive**: measured
/// at 69 ms, peaking at 227 ms. On a 1 Hz timer that alone would be ~7% of a core, so it is
/// polled at 5 s and only while a panel that needs it is on screen. Views read the cached
/// snapshot; nothing spawns a process on a render path.
@MainActor
final class TailscaleManager: ObservableObject {
    static let shared = TailscaleManager()

    struct Node: Identifiable, Equatable {
        let id: String
        let name: String
        let address: String
        let os: String
        let online: Bool
        let isSelf: Bool
        let owner: String?
    }

    @Published private(set) var nodes: [Node] = []
    @Published private(set) var backendState: String?
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var lastUpdated: Date?

    /// `true` once a probe has completed, so the panel can tell "nothing yet" from "nothing".
    @Published private(set) var hasProbed = false

    private var watchers = 0
    private var timer: Timer?
    private var isFetching = false

    var isRunning: Bool { backendState == "Running" }

    private init() {}

    func start() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task { [weak self] in
            let json = await XPCHelperClient.shared.tailscale("status")
            await MainActor.run { self?.apply(json) }
        }
    }

    /// Connect or disconnect. Both are slow enough to be worth an immediate refresh after.
    func setEnabled(_ enabled: Bool) {
        Task { [weak self] in
            _ = await XPCHelperClient.shared.tailscale(enabled ? "up" : "down")
            await MainActor.run { self?.refresh() }
        }
    }

    private func apply(_ json: String?) {
        isFetching = false
        hasProbed = true
        lastUpdated = Date()

        guard let data = json?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            statusMessage = "Tailscale not reachable"
            nodes = []
            backendState = nil
            return
        }

        statusMessage = ""
        backendState = root["BackendState"] as? String

        // Peer owners arrive as numeric user ids; the names live in a separate map.
        var owners: [String: String] = [:]
        if let users = root["User"] as? [String: Any] {
            for (id, value) in users {
                if let user = value as? [String: Any], let login = user["LoginName"] as? String {
                    owners[id] = login
                }
            }
        }

        func node(_ raw: [String: Any], isSelf: Bool) -> Node? {
            guard let id = raw["ID"] as? String else { return nil }
            let host = raw["HostName"] as? String ?? id
            let ips = raw["TailscaleIPs"] as? [String] ?? []
            let ownerID = raw["UserID"].map { String(describing: $0) } ?? ""
            return Node(
                id: id,
                name: host,
                address: ips.first(where: { !$0.contains(":") }) ?? ips.first ?? "",
                os: raw["OS"] as? String ?? "",
                online: isSelf ? true : (raw["Online"] as? Bool ?? false),
                isSelf: isSelf,
                owner: owners[ownerID])
        }

        var found: [Node] = []
        if let selfRaw = root["Self"] as? [String: Any], let this = node(selfRaw, isSelf: true) {
            found.append(this)
        }
        if let peers = root["Peer"] as? [String: Any] {
            for value in peers.values {
                if let raw = value as? [String: Any], let peer = node(raw, isSelf: false) {
                    found.append(peer)
                }
            }
        }
        // Online first, then self, then by name — a list you can read top-down.
        found.sort {
            if $0.online != $1.online { return $0.online }
            if $0.isSelf != $1.isSelf { return $0.isSelf }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if found != nodes { nodes = found }
    }
}
