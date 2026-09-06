//
//  SystemAlertManager.swift
//  boringNotch
//
//  The stats strip's own numbers, except these ones speak up.
//

import Defaults
import Foundation
import OSLog
import SwiftUI

// MARK: - What a rule found when it looked

struct AlertReading {
    /// In the rule's own units -- percent, watts, bytes -- not a normalised fraction. A
    /// threshold written as `35` next to a comment saying watts is readable; `0.583` is not.
    let value: Double
    /// The first beat on the right of the notch: `94%`. Left `nil` when what should be shown
    /// is not the reading but what the trigger made of it -- a surge shows what was *gained*,
    /// which the rule cannot know at read time.
    var detail: String?
    /// The second beat, a moment later: `Python`, `8.2 GB swap`. `nil` leaves the right side
    /// on `detail` for the whole four seconds.
    var context: String?
}

/// What makes a reading worth interrupting for.
///
/// Two kinds, and the second is not a variation on the first. A **level** answers *are you
/// nearly out* -- it is the right question for a disk or a quota. A **surge** answers
/// *did something just start eating* -- and no level can ask it: Obsidian taking 2 GB moves
/// memory from 40% to 52%, which is nowhere near any sensible limit and is exactly the moment
/// worth knowing about. Shipping only levels meant the alert that mattered most never fired.
enum AlertTrigger {
    /// Above `above` for `sustained` consecutive samples. Silent again below `rearmBelow` --
    /// deliberately not the same number, because a figure sitting on one line crosses it
    /// dozens of times a minute.
    case level(above: Double, rearmBelow: Double, sustained: Int)
    /// Gained more than `gaining` within the last `within` samples, measured from the window's
    /// floor. The absolute level is not consulted at all.
    case surge(gaining: Double, within: Int)
    /// Not measured at all. Something outside the app decided this happened and said so, and
    /// the rule exists only to carry the label, the icon and the settings switch. Never polled.
    case event
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

    /// What counts as worth saying: a level held, or a jump.
    let trigger: AlertTrigger

    /// Renders whatever the trigger measured, for rules whose `read` leaves `detail` nil.
    /// A surge passes the amount gained, not the level it reached.
    let format: @Sendable (Double) -> String

    /// `nil` means *cannot say* -- charging, no usage file yet, a figure not sampled. That is
    /// not the same as *below the line*, and the difference matters: `nil` leaves the latch
    /// exactly as it was instead of quietly re-arming a rule that is still over its threshold.
    let read: @MainActor (AlertSources) -> AlertReading?

    /// Who to blame, looked up once at the moment the rule fires and never on the sampling
    /// path. `nil` here, or a `nil` result, simply leaves `context` as `read` left it.
    let attribute: (@Sendable () async -> String?)?

    /// The icon's colour, from the same three steps the stats strip uses. Red for a machine
    /// in trouble, orange for something worth a look, green for a result.
    let tint: Color

    /// Derived from the id so that adding a rule cannot forget to add its switch.
    let enabled: Defaults.Key<Bool>

    init(
        id: String, label: String, icon: String, title: String,
        trigger: AlertTrigger,
        tint: Color = StatsPalette.critical,
        read: @escaping @MainActor (AlertSources) -> AlertReading? = { _ in nil },
        format: @escaping @Sendable (Double) -> String = { String(Int($0)) },
        attribute: (@Sendable () async -> String?)? = nil
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.title = title
        self.trigger = trigger
        self.tint = tint
        self.format = format
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
    static let all: [AlertRule] = [
        .cpu, .memory, .memorySurge, .drain, .tokens,
        .claudeDone, .claudeWaiting, .claudeStalled, .claudeStarted,
    ]

    static let cpu = AlertRule(
        id: "cpu",
        label: "CPU high",
        icon: "cpu",
        title: "CPU",
        trigger: .level(above: 90, rearmBelow: 75, sustained: 30),
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
        trigger: .level(above: 90, rearmBelow: 75, sustained: 30),
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

    /// The one a threshold cannot catch.
    ///
    /// Opening a 2 GB vault in Obsidian takes memory from roughly 40% to 52% -- a jump worth
    /// knowing about that never comes near the 90% the level rule waits for. Measured against
    /// the floor of the last minute rather than the reading exactly a minute ago, so a figure
    /// that dipped and then climbed still counts as having climbed.
    static let memorySurge = AlertRule(
        id: "memorySurge",
        label: "Memory",
        icon: "arrow.up.forward.circle",
        title: "Sudden memory jumps",
        trigger: .surge(gaining: 1.5 * 1_073_741_824, within: 60),
        tint: StatsPalette.serious,
        read: { sources in AlertReading(value: Double(sources.stats.memoryUsedBytes)) },
        format: { "+\(Units.bytes(UInt64(max($0, 0))))" },
        attribute: { await XPCHelperClient.shared.topMemoryProcess() })

    static let drain = AlertRule(
        id: "drain",
        label: "Draining",
        icon: "battery.25",
        title: "Battery drain",
        trigger: .level(above: 35, rearmBelow: 20, sustained: 30),
        tint: StatsPalette.serious,
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
        },
        // Was the one rule that fired a number and named nobody: `Draining - 48 W` is a fact
        // you can do nothing with. Percentage left is the weakest thing it could say second,
        // since the same figure is already three inches away in the menu bar.
        attribute: { await XPCHelperClient.shared.topPowerProcess() })

    static let tokens = AlertRule(
        id: "tokens",
        label: "Tokens",
        icon: "gauge.with.dots.needle.67percent",
        // Three seconds, not thirty. A quota does not flicker, and the figure behind it only
        // changes when the file is re-read once a minute -- waiting half a minute for a
        // number that cannot move is waiting for nothing.
        title: "Plan limits",
        trigger: .level(above: 90, rearmBelow: 75, sustained: 3),
        tint: StatsPalette.serious,
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

    /// A tab finished, is blocked, went quiet, or just started. Four rules rather than one
    /// because each gets its own switch: `Started` is the noisiest of them and the first
    /// anyone will want to turn off, and that has to be possible without losing `Done`.
    ///
    /// None of them are measured. The event has already happened by the time anything hears
    /// about it, so these carry only presentation. Fired by `SystemAlertManager.fire`.
    static let claudeDone = AlertRule(
        id: "claudeDone",
        label: "Claude",
        icon: "checkmark.circle",
        title: "Claude Code finished",
        trigger: .event,
        tint: StatsPalette.good)

    /// Blocked on a permission prompt. Worth more than `Done`: a tab that stopped to ask
    /// something is burning wall-clock doing nothing, and it is the state least likely to be
    /// noticed, because nothing about it looks unfinished.
    static let claudeWaiting = AlertRule(
        id: "claudeWaiting",
        label: "Claude",
        icon: "hand.raised",
        title: "Claude Code needs you",
        trigger: .event,
        tint: StatsPalette.critical)

    /// Idle, waiting for input long enough that macOS raised it.
    static let claudeStalled = AlertRule(
        id: "claudeStalled",
        label: "Claude",
        icon: "hourglass",
        title: "Claude Code went quiet",
        trigger: .event,
        tint: StatsPalette.serious)

    static let claudeStarted = AlertRule(
        id: "claudeStarted",
        label: "Claude",
        icon: "play.circle",
        title: "Claude Code started",
        trigger: .event,
        tint: .effectiveAccent)

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

    /// When each distinct event was last announced, keyed by rule *and* subject. Only used to
    /// swallow a genuine duplicate; see `fire`.
    private var eventSeen: [String: Date] = [:]

    /// `sampleCPU` leaves `cpuUsage` at its previous value on the first tick after any
    /// `start()`, because a rate needs two readings of a monotonic counter before it exists.
    /// Nothing here should read that stale figure as evidence of anything.
    private var sawFirstSample = false

    private struct Latch {
        var isAbove = false
        var samples = 0
        var firedAt: Date?
        /// Recent readings, for surge rules only. A level rule needs no memory of its past.
        var window: [Double] = []
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
            // An event rule has no reading to take. Skipping it here rather than letting it
            // return nil keeps the sampling path honest about what it actually costs.
            if case .event = rule.trigger { continue }
            evaluate(rule)
        }
    }

    /// Announce something that has already happened. No threshold, no sustain, no cooldown:
    /// an event arrives already decided, and the only judgement left is whether this is the
    /// same one twice.
    ///
    /// Deliberately not the ten-minute cooldown the threshold rules use. That window exists to
    /// stop one continuous condition being reported over and over; three tabs finishing inside
    /// a minute are three separate facts, and swallowing the second and third would defeat the
    /// entire point of the feature. So the key includes the subject, and the window is five
    /// seconds -- long enough for a duplicated hook, short enough to never merge two tabs.
    func fire(_ id: String, detail: String, context: String?) {
        guard started, Defaults[.systemAlerts] else { return }
        guard let rule = AlertRule.all.first(where: { $0.id == id }),
              Defaults[rule.enabled]
        else { return }

        let now = Date()
        let key = "\(id)|\(detail)"
        if let last = eventSeen[key], now.timeIntervalSince(last) < 5 { return }
        eventSeen = eventSeen.filter { now.timeIntervalSince($0.value) < 60 }
        eventSeen[key] = now

        logger.notice("\(id, privacy: .public) event: \(detail, privacy: .public)")
        show(rule, detail: detail, context: context)
    }

    private func evaluate(_ rule: AlertRule) {
        var latch = latches[rule.id] ?? Latch()
        defer { latches[rule.id] = latch }

        guard let reading = rule.read(sources) else { return }

        // Both kinds of trigger collapse to the same three numbers, so the latch below does
        // not need to know which kind it is holding.
        let signal: Double, fireAt: Double, rearmAt: Double, needed: Int
        switch rule.trigger {
        case .level(let above, let rearmBelow, let sustained):
            signal = reading.value
            fireAt = above
            rearmAt = rearmBelow
            needed = sustained

        case .surge(let gaining, let within):
            latch.window.append(reading.value)
            if latch.window.count > within {
                latch.window.removeFirst(latch.window.count - within)
            }
            // Against the window's floor, not against the reading exactly `within` ago: a
            // figure that dipped and then climbed has still climbed, and the dip is no reason
            // to miss it.
            signal = reading.value - (latch.window.min() ?? reading.value)
            fireAt = gaining
            // Half the jump. Nothing else to reuse here -- a surge has no natural "normal" the
            // way a percentage does, and the window rolling forward re-arms it anyway once the
            // new plateau becomes the floor.
            rearmAt = gaining / 2
            // A jump is one event. There is nothing to sustain.
            needed = 1

        case .event:
            return  // Unreachable: `check` filters these out. Here so adding a trigger kind
                    // is a compile error rather than a rule that silently never fires.
        }

        if signal < rearmAt {
            latch.isAbove = false
            latch.samples = 0
            return
        }
        guard signal >= fireAt else {
            // In the gap between re-arming and firing: not worth announcing, not yet worth
            // forgetting. Having two numbers instead of one is the entire point of the gap.
            latch.samples = 0
            return
        }

        latch.samples += 1
        guard !latch.isAbove, latch.samples >= needed else { return }

        // Latch on the crossing whether or not it gets announced. Inside the quiet window the
        // alert is dropped rather than deferred: the next one should wait for the figure to
        // come back down and cross again, not arrive the instant the cooldown lapses.
        latch.isAbove = true
        if let firedAt = latch.firedAt,
           Date().timeIntervalSince(firedAt) < Defaults[.systemAlertCooldown] * 60 {
            return
        }
        latch.firedAt = Date()
        announce(rule, detail: reading.detail ?? rule.format(signal), context: reading.context)
    }

    private func announce(_ rule: AlertRule, detail: String, context: String?) {
        logger.notice("\(rule.id, privacy: .public) fired: \(detail, privacy: .public)")

        guard let attribute = rule.attribute else {
            show(rule, detail: detail, context: context)
            return
        }
        // The one expensive thing here, and deliberately not on the sampling path: walking
        // every process costs three orders of magnitude more than the two Mach calls behind
        // `cpuUsage`. It runs once, after a rule has already spent thirty seconds deciding it
        // has something to say, and the extra wait is about 300 ms.
        Task { @MainActor in
            let found = await attribute()
            logger.notice("\(rule.id, privacy: .public) blamed \(found ?? "nobody", privacy: .public)")
            show(rule, detail: detail, context: found ?? context)
        }
    }

    private func show(_ rule: AlertRule, detail: String, context: String?) {
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .systemAlert, duration: 4, value: 1,
            icon: rule.icon,
            detail: detail,
            detailSecondary: context ?? "",
            label: rule.label,
            tint: rule.tint)
    }
}
