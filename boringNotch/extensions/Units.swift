//
//  Units.swift
//  boringNotch
//
//  How a figure on the stats strip picks its unit — and how wide the cell holding it
//  has to be.
//

import Foundation

/// Unit scaling for every figure the notch prints as a number with a suffix.
///
/// **Two bases, and the split is not pedantry.** A *bit* rate is decimal by definition: a
/// gigabit is a thousand megabits, which is what the radio, the router and the ISP all
/// mean by it. A *byte* count is what the kernel hands back in powers of two, and it is
/// what Activity Monitor prints. Picking one base for both would make the notch disagree
/// with something on every page — `1.77 Gbps` for a link every other tool calls 1.81, or a
/// memory figure a gigabyte off what Activity Monitor shows. So bits divide by 1000 and
/// bytes divide by 1024, and each formatter here knows which it is.
///
/// **Precision is uniform: a tenth below 100, whole numbers above.** Past three digits the
/// decimal is a character that changes every sample and settles nothing — nobody reads free
/// disk to a tenth of a gigabyte. Below 100 there is room for it and it carries real
/// information, which is why `12.4 GB` of memory is worth more than `12 GB`.
///
/// **Each formatter publishes its own widest output.** The cells reserve width up front so a
/// growing figure does not shove the row along (see `gauge(_:_:widest:)`), and a reservation
/// written out by hand goes stale the moment a tier is added — `"999 KB/s"` was still being
/// reserved for a formatter that could return `"999.9 MB/s"`, so a fast download overlapped
/// its neighbour every time. Keeping the maximum next to the format is what stops that
/// happening again.
enum Units {

    // MARK: Byte counts

    /// Memory, swap, free disk: the largest binary unit the figure fills.
    static func bytes(_ count: UInt64) -> String {
        scaled(Double(count), base: 1024, units: ["B", "KB", "MB", "GB", "TB", "PB"])
    }

    /// Four digits and the unit — `1023 GB`, the widest `bytes(_:)` can return.
    ///
    /// Wider than `99.9 GB` despite the same character count: the strip's digits are
    /// monospaced but its period is not, so four digits beat three and a point.
    static let widestBytes = "1023 GB"

    // MARK: Byte rates

    /// Throughput, in bytes per second. Idle reads `0 B/s` rather than the `0 KB/s` this
    /// used to print, which was a rounded-down lie for everything under a kilobyte.
    ///
    /// No tenths until megabytes: a tenth of a kilobyte per second is a hundred bytes, and
    /// throughput is noisy enough that the digit would change on every sample while saying
    /// nothing. This is the cell that sits in the KB range most of the day, so it is the
    /// one place the extra digit would actually be read — and ignored.
    static func byteRate(_ bytesPerSecond: Double) -> String {
        scaled(max(bytesPerSecond, 0), base: 1024, units: ["B/s", "KB/s", "MB/s", "GB/s"],
               decimalsFrom: 2)
    }

    /// `1023 KB/s` — the KB tier runs furthest before promoting, so it sets the width.
    static let widestByteRate = "1023 KB/s"

    // MARK: Bit rates

    /// A link rate, given in megabits as every macOS Wi-Fi API reports it, printed in
    /// whatever decimal unit fits. Wi-Fi 6E negotiates past a gigabit routinely and Wi-Fi 7
    /// goes to five, so `1814 Mbps` is a number the reader has to divide in their head.
    static func bitRate(megabitsPerSecond: Double) -> String {
        scaled(max(megabitsPerSecond, 0) * 1_000_000, base: 1000,
               units: ["bps", "Kbps", "Mbps", "Gbps", "Tbps"])
    }

    /// `99.9 Mbps` — a decimal base promotes at 1000, so three digits and a point is as
    /// wide as this gets.
    static let widestBitRate = "99.9 Mbps"

    // MARK: -

    /// Promote until the figure fits, then print it at the row's precision.
    ///
    /// The promotion test runs on the *rounded* figure, not the raw one. Checking the raw
    /// value lets 1023.7 GB through the loop and then rounds it to `1024 GB` on the way
    /// out — a unit the loop had just decided against, and a fifth digit the cell never
    /// reserved room for.
    /// - Parameter decimalsFrom: the first tier that earns a decimal place. Everything
    ///   below it prints whole.
    private static func scaled(
        _ value: Double, base: Double, units: [String], decimalsFrom: Int = 1
    ) -> String {
        var value = value
        var index = 0
        while index < units.count - 1, rounded(value) >= base {
            value /= base
            index += 1
        }
        // The base unit is a count of bytes or bits. A tenth of one is not a measurement.
        guard index >= decimalsFrom else {
            return String(format: "%.0f %@", value, units[index])
        }

        let figure = rounded(value)
        return figure < 100
            ? String(format: "%.1f %@", figure, units[index])
            : String(format: "%.0f %@", figure, units[index])
    }

    /// The figure as it will actually be printed, which is what every threshold here has
    /// to be judged against.
    private static func rounded(_ value: Double) -> Double {
        value < 100 ? (value * 10).rounded() / 10 : value.rounded()
    }
}
