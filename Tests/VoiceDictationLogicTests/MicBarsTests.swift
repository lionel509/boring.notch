import XCTest
import Foundation
@testable import VoiceDictationLogic

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class MicBarsTests: XCTestCase {
    func testBulgeIsSymmetricWithCentreOne() {
        for count in [1, 5, 7, 9] {
            for i in 0..<count {
                XCTAssertEqual(MicBars.bulge(i, count: count), MicBars.bulge(count - 1 - i, count: count), accuracy: 1e-6)
            }
            XCTAssertEqual(MicBars.bulge(count / 2, count: count), 1, accuracy: 1e-6)
        }
    }

    func testOuterBarOfSevenIsPointFourThreeSevenFive() {
        XCTAssertEqual(MicBars.bulge(0, count: 7), 0.4375, accuracy: 1e-6)
    }

    func testLevelsStayInUnitRange() {
        var rng = SplitMix64(state: 0xBA25)
        for _ in 0..<500 {
            let level = Float.random(in: -1...2, using: &rng)
            let time = Double.random(in: 0...100, using: &rng)
            for value in MicBars.levels(level: level, time: time, count: 7, ripple: Bool.random(using: &rng)) {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testZeroLevelWithoutRippleIsAllZeros() {
        XCTAssertEqual(MicBars.levels(level: 0, time: 3.7, count: 7, ripple: false), [Float](repeating: 0, count: 7))
    }

    func testRippleStaysWithinItsAmplitude() {
        var rng = SplitMix64(state: 0x21B)
        for _ in 0..<500 {
            let i = Int.random(in: 0..<7, using: &rng)
            let time = Double.random(in: 0...50, using: &rng)
            let value = MicBars.ripple(i, count: 7, time: time)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, MicBars.rippleAmplitude + 1e-6)
        }
    }

    func testLevelsAreMonotoneInLevel() {
        var rng = SplitMix64(state: 0x0E0E)
        for _ in 0..<300 {
            let a = Float.random(in: 0...1, using: &rng)
            let b = Float.random(in: a...1, using: &rng)
            let time = Double.random(in: 0...50, using: &rng)
            for ripple in [false, true] {
                let low = MicBars.levels(level: a, time: time, count: 7, ripple: ripple)
                let high = MicBars.levels(level: b, time: time, count: 7, ripple: ripple)
                for bar in 0..<7 {
                    XCTAssertLessThanOrEqual(low[bar], high[bar] + 1e-6, "bar \(bar) fell as level rose")
                }
            }
        }
    }

    func testTwoSixtiethStepsEqualOneTwoSixtiethStep() {
        let once = MicBars.smooth(0.2, toward: 0.9, dt: 2.0 / 60.0)
        let twice = MicBars.smooth(MicBars.smooth(0.2, toward: 0.9, dt: 1.0 / 60.0), toward: 0.9, dt: 1.0 / 60.0)
        XCTAssertEqual(once, twice, accuracy: 1e-5)
    }

    func testRiseReachesNinetyPercentWithinAQuarterSecond() {
        var v: Float = 0
        for _ in 0..<8 {
            v = MicBars.smooth(v, toward: 1, dt: 1.0 / 30.0)
        }
        // Eight ticks at 30 Hz is 0.267 s.
        XCTAssertGreaterThan(v, 0.9)
    }

    func testFallStillAboveThreeTenthsAfterAHundredMilliseconds() {
        let v = MicBars.smooth(1, toward: 0, dt: 0.1)
        XCTAssertGreaterThan(v, 0.3)
    }

    func testRiseIsFasterThanFall() {
        let rise = MicBars.smooth(0, toward: 1, dt: 1.0 / 30.0)
        let fall = 1 - MicBars.smooth(1, toward: 0, dt: 1.0 / 30.0)
        XCTAssertGreaterThan(rise, fall)
    }
}
