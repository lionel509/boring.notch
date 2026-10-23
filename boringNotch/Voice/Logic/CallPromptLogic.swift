import Foundation

/// Maps mic-holding processes to calls. Pure: no I/O, and window-title text is matched here but never stored.
enum CallApps {
    static func matches(_ bundleID: String, base: String) -> Bool {
        bundleID == base || bundleID.hasPrefix(base + ".")
    }

    static let native: [(base: String, id: String, name: String)] = [
        ("us.zoom.xos", "zoom", "Zoom"),
        ("com.hnc.Discord", "discord", "Discord"),
        ("com.hnc.DiscordPTB", "discord", "Discord"),
        ("com.hnc.DiscordCanary", "discord", "Discord"),
        ("com.apple.FaceTime", "facetime", "FaceTime"),
        ("com.apple.avconferenced", "facetime", "FaceTime"),
        ("com.microsoft.teams2", "teams", "Teams"),
        ("com.microsoft.teams", "teams", "Teams"),
        ("com.tinyspeck.slackmacgap", "slack", "Slack"),
        ("Cisco-Systems.Spark", "webex", "Webex"),
        ("com.cisco.webexmeetingsapp", "webex", "Webex"),
        ("net.whatsapp.WhatsApp", "whatsapp", "WhatsApp"),
        ("ru.keepcoder.Telegram", "telegram", "Telegram"),
        ("org.telegram.desktop", "telegram", "Telegram"),
    ]

    static let browsers: [String] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.apple.WebKit",          // Safari's GPU process holds the mic
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "app.zen-browser.zen",
    ]

    /// Matched in order, case-insensitively, against a browser window title.
    static let services: [(id: String, name: String, prefix: String?, contains: [String])] = [
        ("meet", "Google Meet", "Meet - ", ["Google Meet"]),
        ("zoom", "Zoom", nil, ["Zoom Meeting", "Zoom Workplace"]),
        ("teams", "Teams", nil, ["Microsoft Teams"]),
        ("jitsi", "Jitsi Meet", nil, ["Jitsi Meet"]),
        ("webex", "Webex", nil, ["Webex"]),
        ("whereby", "Whereby", nil, ["Whereby"]),
        ("discord", "Discord", nil, ["Discord"]),
        ("slack", "Slack", nil, ["Slack"]),
    ]

    static func nativeCall(for c: MicClient) -> DetectedCall? {
        guard let row = native.first(where: { matches(c.bundleID, base: $0.base) }) else { return nil }
        return DetectedCall(id: row.id, name: row.name, pid: c.pid, viaBrowser: false)
    }

    static func isBrowser(_ bundleID: String) -> Bool {
        browsers.contains { matches(bundleID, base: $0) }
    }

    /// Walks the titles in order; the first service that matches a title wins. Only the table's id and name leave this function.
    static func browserCall(titles: [String], pid: Int32) -> DetectedCall? {
        for title in titles {
            let lower = title.lowercased()
            for service in services where serviceMatches(service, lowercasedTitle: lower) {
                return DetectedCall(id: service.id, name: service.name, pid: pid, viaBrowser: true)
            }
        }
        return nil
    }

    private static func serviceMatches(_ service: (id: String, name: String, prefix: String?, contains: [String]),
                                       lowercasedTitle lower: String) -> Bool {
        if let prefix = service.prefix, lower.hasPrefix(prefix.lowercased()) { return true }
        return service.contains.contains { lower.contains($0.lowercased()) }
    }

    static func displayName(for id: String) -> String {
        if let row = native.first(where: { $0.id == id }) { return row.name }
        if let row = services.first(where: { $0.id == id }) { return row.name }
        return id
    }

    static func indicatorName(_ clients: [MicClient]) -> String? {
        clients.first(where: { $0.name != nil })?.name
    }
}

/// Decides when the notch asks about a call, and what it does after an answer. Pure: the caller passes the
/// time, and the grace window is checked on the next event (no timers).
enum CallPromptLogic {
    static let endGrace: TimeInterval = 120
    static let promptTimeout: TimeInterval = 15

    enum Effect: Equatable {
        case show(DetectedCall), hide(DetectedCall), begin(DetectedCall), end(DetectedCall), mute(String)
    }

    struct State: Equatable {
        var live: [String: DetectedCall] = [:]
        var liveOrder: [String] = []
        var pending: DetectedCall? = nil
        var answers: [String: CallAnswer] = [:]
        var releasedAt: [String: TimeInterval] = [:]
        var transcribing: Set<String> = []
        init() {}
    }

    static func update(_ s: inout State, calls: [DetectedCall], muted: Set<String>, at now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []

        // (a) Dedupe by id, keeping the first.
        var incoming: [DetectedCall] = []
        var seen = Set<String>()
        for call in calls where seen.insert(call.id).inserted {
            incoming.append(call)
        }
        let incomingIDs = Set(incoming.map(\.id))

        // (b) Forget releases older than the grace window, with their answers.
        let expired = s.releasedAt.compactMap { id, t in now - t >= endGrace ? id : nil }
        for id in expired {
            s.releasedAt[id] = nil
            s.answers[id] = nil
        }

        // (c) Ids that left: remember when, drop a pending prompt, end a transcription.
        for id in s.liveOrder where !incomingIDs.contains(id) {
            s.releasedAt[id] = now
            if let p = s.pending, p.id == id {
                s.pending = nil
                effects.append(.hide(p))
            }
            if let old = s.live[id], s.transcribing.remove(id) != nil {
                effects.append(.end(old))
            }
        }

        // (d) Ids that arrived: resume a yes'd call within grace, otherwise start fresh.
        for call in incoming where s.live[call.id] == nil {
            if let t = s.releasedAt[call.id], now - t < endGrace {
                s.releasedAt[call.id] = nil
                if s.answers[call.id] == .yes {
                    s.transcribing.insert(call.id)
                    effects.append(.begin(call))
                }
            } else {
                s.releasedAt[call.id] = nil
                s.answers[call.id] = nil
            }
        }

        // (e) Live set becomes the incoming set.
        s.live = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        s.liveOrder = incoming.map(\.id)

        // (f) Ask about the next unanswered, unmuted call if nothing is on screen.
        effects += promptNext(&s, muted: muted)
        return effects
    }

    static func answer(_ s: inout State, _ a: CallAnswer, muted: Set<String>, at now: TimeInterval) -> [Effect] {
        guard let call = s.pending else { return [] }
        s.pending = nil
        var effects: [Effect] = [.hide(call)]
        switch a {
        case .yes:
            s.answers[call.id] = .yes
            s.transcribing.insert(call.id)
            effects.append(.begin(call))
        case .no:
            s.answers[call.id] = .no
        case .never:
            s.answers[call.id] = .no
            effects.append(.mute(call.id))
        }
        let nextMuted = a == .never ? muted.union([call.id]) : muted
        effects += promptNext(&s, muted: nextMuted)
        return effects
    }

    /// Stale timeouts (the prompt has moved on) do nothing. A live timeout counts as "no".
    static func timeout(_ s: inout State, callID: String, muted: Set<String>, at now: TimeInterval) -> [Effect] {
        guard s.pending?.id == callID else { return [] }
        return answer(&s, .no, muted: muted, at: now)
    }

    private static func promptNext(_ s: inout State, muted: Set<String>) -> [Effect] {
        guard s.pending == nil else { return [] }
        guard let id = s.liveOrder.first(where: { s.answers[$0] == nil && !muted.contains($0) }),
              let call = s.live[id] else { return [] }
        s.pending = call
        return [.show(call)]
    }
}
