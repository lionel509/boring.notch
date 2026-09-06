//
//  SystemAlertManager.swift
//  boringNotch
//
//  The stats strip's own numbers, except these ones speak up.
//

import Defaults
import Foundation
import OSLog

// MARK: - What a rule found when it looked

struct AlertReading {
    /// In the rule's own units -- percent, watts -- not a normalised fraction. A threshold
    /// written as `35` next to a comment saying watts is readable; `0.583` is not.
    let value: Double
    /// The first beat on the right of the notch: `94%`.
    let detail: String
    /// The second beat, a moment later: `Python`, `8.2 GB swap`. `nil` leaves the right side
    /// on `detail` for the whole four seconds.
    var context: String?
}

/// Everything a rule is allowed to read.
///
/// It exists so a rule closure can reach any figure the app samples without the registry
/// having to know which manager that particular rule cares about -- which is what stops the
/// fifth rule needing a new wire run to it.
@MainActor
struct AlertSources {
    let stats = SystemStatsManager.shared
    let usage = RouterUsageManager.shared
    let battery = BatteryStatusViewModel.shared
}

// MARK: - A rule

/// One thing worth interrupting for.
///
/// Overseer kept these in a SQLite table with severities, acknowledgements and an alert
/// history. The table was the wrong half to bring: what earns its place is the shape of a
/// rule -- a metric, a line, and a name -- and the thresholds it had already settled on.
/// Everything else here is four values and a closure.
struct AlertRule: Identifiable {
    let id: String

    /// The left slot of the notch, which is about 63 pt. One short word, two at a push:
    /// `CPU high` fits and `High CPU usage` does not. `InlineHUD` records what happened the
    /// last time something longer was tried -- `"Disconnected"` came out as `"Disconne..."`.
    let label: String

    /// SF Symbol, drawn at 20x15.
    let icon: String

    /// The settings row.
    let title: String

    /// Announce above this, in the units `read` returns.
    let threshold: Double

    /// Go quiet again below this. Deliberately not the same number: a value sitting exactly
    /// on one line crosses it dozens of times a minute. 75 is `StatsPalette`'s own boundary
    /// between normal and worth-a-look, so the gap reuses a judgement the project already
    /// made rather than inventing a second one.
    let rearm: Double

    /// Consecutive samples over the line before it counts. At 1 Hz this is seconds.
    let sustained: Int

    /// `nil` means *cannot say* -- charging, no usage file yet, a figure not sampled. That is
    /// not the same as *below the line*, and the difference matters: `nil` leaves the latch
    /// exactly as it was instead of quietly re-arming a rule that is still over its threshold.
    let read: @MainActor (AlertSources) -> AlertReading?

    /// Who to blame, looked up once at the moment the rule fires and never on the sampling
    /// path. `nil` here, or a `nil` result, simply leaves `context` as `read` left it.
    let attribute: (@Sendable () async -> String?)?

    /// Derived from the id so that adding a rule cannot forget to add its switch.
    let enabled: Defaults.Key<Bool>

    init(
        id: String, label: String, icon: String, title: String,
        threshold: Double, rearm: Double, sustained: Int,
        read: @escaping @MainActor (AlertSources) -> AlertReading?,
        attribute: (@Sendable () async -> String?)? = nil
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.title = title
        self.threshold = threshold
        self.rearm = rearm
        self.sustained = sustained
        self.read = read
        self.attribute = attribute
        self.enabled = Defaults.Key("systemAlert.\(id)", default: true)
    }
}

// MARK: - The registry

extension AlertRule {
    /// Everything the notch will speak up about, in the order it would matter.
    ///
    /// Four is a starting set, not the feature. A fifth is one entry here: the toggle, the
    /// settings row, the latch, the cooldown and the announcement all follow from it.
    /// Thermal state, disk pressure, a weak signal and a Bluetooth device running flat are
    /// all already sampled and are each one literal away -- they are left out today because
    /// four interruptions is enough to find out whether the cadence is right, and getting
    /// that wrong is what makes someone switch the whole feature off.
    static let all: [AlertRule] = [.cpu, .memory, .drain, .tokens]

    static let cpu = AlertRule(
        id: "cpu",
        label: "CPU high",
        icon: "cpu",
        title: "CPU",
        threshold: 90, rearm: 75, sustained: 30,
        read: { sources in
            let percent = sources.stats.cpuUsage * 100
            return AlertReading(value: percent, detail: "\(Int(percent.rounded()))%")
        },
        // Across the XPC boundary on purpose. Everything needed to answer this is refused
        // inside the app sandbox -- `proc_listpids` lists nothing, the process table's own
        // `p_pctcpu` reads 0 for every process, and `proc_pid_rusage` answers for exactly one
        // pid, this one. `BoringNotchXPCHelper` is not sandboxed and carries the details.
        attribute: { await XPCHelperClient.shared.topProcessName() })

    static let memory = AlertRule(
        id: "memory",
        label: "Memory",
        icon: "memorychip",
        title: "Memory",
        threshold: 90, rearm: 75, sustained: 30,
        read: { sources in
            let percent = sources.stats.memoryFraction * 100
            // Swap is the half that explains the percentage. A machine at 96% with no swap is
            // using its memory; a machine at 96% with eight gigabytes of swap is thrashing.
            // Same number, different problem, and only one of them is worth stopping for.
            let swap = sources.stats.swapUsedBytes
            return AlertReading(
                value: percent,
                detail: "\(Int(percent.rounded()))%",
                context: swap >= 1_073_741_824 ? "\(Units.bytes(swap)) swap" : nil)
        })

    static let drain = AlertRule(
        id: "drain",
        label: "Draining",
        icon: "battery.25",
        title: "Battery drain",
        threshold: 35, rearm: 20, sustained: 30,
        read: { sources in
            // Charging is not a quiet kind of draining, it is the other thing entirely.
            // Returning nil rather than zero keeps a cable going in from re-arming a rule
            // that was over the line a second ago.
            guard !sources.battery.isCharging, sources.stats.batteryWatts < 0 else { return nil }
            let watts = abs(sources.stats.batteryWatts)
            return AlertReading(
                value: watts,
                detail: String(format: "%.0f W", watts),
                context: "\(Int(sources.battery.levelBattery.rounded()))% left")
        })

    static let tokens = AlertRule(
        id: "tokens",
        label: "Tokens",
        icon: "gauge.with.dots.needle.67percent",
        // Three seconds, not thirty. A quota does not flicker, and the figure behind it only
        // changes when the file is re-read once a minute -- waiting half a minute for a
        // number that cannot move is waiting for nothing.
        title: "Plan limits",
        threshold: 90, rearm: 75, sustained: 3,
        read: { sources in
            // Both percentages default to zero when their key is missing, so a partial or
            // abandoned file reads as *plenty of quota left* rather than as no information.
            // The freshness check is what makes a zero here trustworthy.
            guard let limits = sources.usage.limits,
                  let updated = limits.updatedAt,
                  Date().timeIntervalSince(updated) < 3_600
            else { return nil }

            let onFiveHour = limits.fiveHourPercent >= limits.sevenDayPercent
            let worst = max(limits.fiveHourPercent, limits.sevenDayPercent)
            let resets = onFiveHour ? limits.fiveHourResetsAt : limits.sevenDayResetsAt
            return AlertReading(
                value: worst,
                detail: "\(onFiveHour ? "5-hour" : "7-day") \(Int(worst.rounded()))%",
                context: resets.map { "resets \(Self.clock.string(from: $0))" })
        })

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - The manager

@MainActor
final class SystemAlertManager {
    static let shared = SystemAlertManager()
    private init() {}

    private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "SystemAlert")
    private let sources = AlertSources()

    private var started = false
    private var latches: [String: Latch] = [:]
    private var usageTimer: Timer?

    /// `sampleCPU` leaves `cpuUsage` at its previous value on the first tick after any
    /// `start()`, because a rate needs two readings of a monotonic counter before it exists.
    /// Nothing here should read that stale figure as evidence of anything.
    private var sawFirstSample = false

    private struct Latch {
        var isAbove = false
        var samples = 0
        var firedAt: Date?
    }

    func start() {
        guard !started else { return }
        started = true

        // A permanent claim on the sampler. `start()`/`stop()` are reference counted off the
        // stats strip appearing and disappearing, so without this the machine is only measured
        // while the notch is open -- which is the one time an alert has nothing to tell you.
        // The strip's `stop()` now decrements to one rather than to zero.
        SystemStatsManager.shared.start()

        // The usage log has no clock of its own: `refresh()` runs at launch, on notch open and
        // on settings open. A quota alert that only notices when you happen to open the notch
        // is the notch reporting what you were already looking at. The read is incremental --
        // it parses only bytes appended since last time -- so a minute is cheap.
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in RouterUsageManager.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
    }

    /// Called from `SystemStatsManager.sample()`, once a second, with every figure fresh and
    /// already on the main actor.
    func check() {
        guard started, Defaults[.systemAlerts] else { return }
        guard sawFirstSample else { sawFirstSample = true; return }

        for rule in AlertRule.all where Defaults[rule.enabled] {
            evaluate(rule)
        }
    }

    private func evaluate(_ rule: AlertRule) {
        var latch = latches[rule.id] ?? Latch()
        defer { latches[rule.id] = latch }

        guard let reading = rule.read(sources) else { return }

        if reading.value < rule.rearm {
            latch.isAbove = false
            latch.samples = 0
            return
        }
        guard reading.value >= rule.threshold else {
            // In the gap between re-arming and firing: not worth announcing, not yet worth
            // forgetting. Having two numbers instead of one is the entire point of the gap.
            latch.samples = 0
            return
        }

        latch.samples += 1
        guard !latch.isAbove, latch.samples >= rule.sustained else { return }

        // Latch on the crossing whether or not it gets announced. Inside the quiet window the
        // alert is dropped rather than deferred: the next one should wait for the figure to
        // come back down and cross again, not arrive the instant the cooldown lapses.
        latch.isAbove = true
        if let firedAt = latch.firedAt,
           Date().timeIntervalSince(firedAt) < Defaults[.systemAlertCooldown] * 60 {
            return
        }
        latch.firedAt = Date()
        announce(rule, reading)
    }

    private func announce(_ rule: AlertRule, _ reading: AlertReading) {
        logger.notice("\(rule.id, privacy: .public) at \(Int(reading.value), privacy: .public)")

        guard let attribute = rule.attribute else {
            show(rule, reading)
            return
        }
        // The one expensive thing here, and deliberately not on the sampling path: walking
        // every process costs three orders of magnitude more than the two Mach calls behind
        // `cpuUsage`. It runs once, after a rule has already spent thirty seconds deciding it
        // has something to say, and the extra wait is about 300 ms.
        Task { @MainActor in
            var enriched = reading
            let found = await attribute()
            if let found { enriched.context = found }
            logger.notice("\(rule.id, privacy: .public) blamed \(found ?? "nobody", privacy: .public)")
            show(rule, enriched)
        }
    }

    private func show(_ rule: AlertRule, _ reading: AlertReading) {
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .systemAlert, duration: 4, value: 1,
            icon: rule.icon,
            detail: reading.detail,
            detailSecondary: reading.context ?? "",
            label: rule.label)
    }
}
