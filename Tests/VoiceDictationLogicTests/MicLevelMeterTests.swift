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

final class MicLevelMeterTests: XCTestCase {
    private let rate = 48_000.0

    private func sine(_ count: Int, amplitude: Float, hz: Double = 1000) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 48_000)) }
    }

    private func meter(feeding samples: [Float], piece: Int? = nil) -> MicLevelMeter {
        var m = MicLevelMeter()
        guard let size = piece else {
            m.ingest(samples, sampleRate: rate, channels: 1)
            return m
        }
        var i = 0
        while i < samples.count {
            let end = min(i + size, samples.count)
            m.ingest(Array(samples[i..<end]), sampleRate: rate, channels: 1)
            i = end
        }
        return m
    }

    private var chunk: Int { Int((rate * MicLevelMeter.chunkSeconds).rounded()) }

    func testSineAtTenthAmplitudeReadsMinus23dB() {
        let m = meter(feeding: sine(48_000, amplitude: 0.1))
        XCTAssertEqual(m.chunks, 25)
        XCTAssertEqual(m.lastDB, -23.0, accuracy: 0.2)
    }

    func testSplittingTheInputDoesNotChangeTheReading() {
        let samples = sine(96_000, amplitude: 0.1)
        let whole = meter(feeding: samples)
        for piece in [4096, 1000] {
            let split = meter(feeding: samples, piece: piece)
            XCTAssertEqual(split.chunks, whole.chunks, "piece \(piece)")
            XCTAssertEqual(split.floorDB, whole.floorDB, "piece \(piece)")
            XCTAssertEqual(split.lastDB, whole.lastDB, "piece \(piece)")
            XCTAssertEqual(split.level, whole.level, "piece \(piece)")
        }
    }

    func testTwoSecondsOfZerosIsDigitalSilence() {
        var m = meter(feeding: [Float](repeating: 0, count: 96_000))
        XCTAssertEqual(m.verdict, .digitalSilence)
        XCTAssertEqual(m.level, 0)
        XCTAssertNil(m.floorDB)
        XCTAssertEqual(m.status(elapsed: 2), .noSignal)
        m = meter(feeding: [Float](repeating: 0, count: chunk * 10))
        XCTAssertEqual(m.chunks, 10)
        XCTAssertEqual(m.status(elapsed: 0.5), .waiting)
    }

    func testNoIngestIsNoBuffers() {
        let m = MicLevelMeter()
        XCTAssertEqual(m.verdict, .noBuffers)
        XCTAssertEqual(m.status(elapsed: 1.0), .waiting)
        XCTAssertEqual(m.status(elapsed: 1.5), .noSignal)
    }

    func testEmptyBuffersAreNotSignal() {
        var m = MicLevelMeter()
        for _ in 0..<50 { m.ingest([Float](), sampleRate: 48_000, channels: 1) }
        XCTAssertEqual(m.buffers, 50)
        XCTAssertEqual(m.verdict, .noBuffers)
        XCTAssertEqual(m.status(elapsed: 1.0), .waiting)
        XCTAssertEqual(m.status(elapsed: 1.5), .noSignal)
    }

    func testEmptyUnsafeBuffersAreNotSignal() {
        var m = MicLevelMeter()
        for _ in 0..<50 {
            m.ingest(UnsafeBufferPointer<Float>(start: nil, count: 0), sampleRate: 48_000, channels: 1)
        }
        XCTAssertEqual(m.buffers, 50)
        XCTAssertEqual(m.verdict, .noBuffers)
        XCTAssertEqual(m.status(elapsed: 1.5), .noSignal)
    }

    func testSpeechAfterQuietNoiseLevelsToOne() {
        // -60 dB, then -30 dB. The floor follows the quiet part.
        let quiet = sine(48_000, amplitude: 0.001 * Float(2).squareRoot())
        let loud = sine(48_000, amplitude: 0.0316 * Float(2).squareRoot())
        var m = meter(feeding: quiet)
        XCTAssertEqual(m.floorDB ?? 0, -60, accuracy: 0.5)
        m.ingest(loud, sampleRate: rate, channels: 1)
        XCTAssertEqual(m.level, 1)
        XCTAssertGreaterThanOrEqual(m.voicedChunks, 20)
    }

    func testTakeOpeningWithSpeechCapsTheFloorAtMinus50() {
        let m = meter(feeding: sine(48_000, amplitude: 0.0316 * Float(2).squareRoot()))
        XCTAssertEqual(m.floorDB, -50)
    }

    func testVeryQuietNoiseClampsTheFloorAtMinus80() {
        // -85 dB RMS.
        let m = meter(feeding: sine(48_000, amplitude: 7.95e-5 * Float(2).squareRoot()))
        XCTAssertEqual(m.floorDB, -80)
    }

    /// `n` samples alternating +rms and -rms, so every chunk's RMS is exactly `rms`.
    private func steady(_ n: Int, rms: Float) -> [Float] {
        (0..<n).map { $0 % 2 == 0 ? rms : -rms }
    }

    func testNoiseFloorRisesWhenTheRoomGetsLouder() {
        // A take opens at -75 dB, then sits in -55 dB room noise for 20 s.
        // At 1.25 dB a second the floor needs 16 s to reach -55.
        var m = MicLevelMeter()
        m.ingest(steady(chunk * 2, rms: Float(pow(10.0, -75.0 / 20))), sampleRate: rate, channels: 1)
        m.ingest(steady(960_000, rms: Float(pow(10.0, -55.0 / 20))), sampleRate: rate, channels: 1)
        XCTAssertEqual(m.floorDB ?? 0, -55, accuracy: 0.01)
        XCTAssertLessThan(m.level, 0.1)
        XCTAssertEqual(m.status(elapsed: 20.1), .quiet)
    }

    func testTenSecondsOfLoudSoundAfterAQuietStartStillReadsHigh() {
        // A take opens at -75 dB, then holds -45 dB for 10 s. The floor climbs only
        // 12.5 dB in that time, so the level stays near full and the take is never quiet.
        var m = MicLevelMeter()
        m.ingest(steady(chunk * 2, rms: Float(pow(10.0, -75.0 / 20))), sampleRate: rate, channels: 1)
        m.ingest(steady(480_000, rms: Float(pow(10.0, -45.0 / 20))), sampleRate: rate, channels: 1)
        XCTAssertTrue((0.85...0.90).contains(m.level), "level \(m.level)")
        XCTAssertNotEqual(m.status(elapsed: 10.1), .quiet)
    }

    func testOneSecondOfAQuietToneIsSignal() {
        // Amplitude 0.1 is far above the 1e-6 digital-silence line.
        XCTAssertEqual(meter(feeding: sine(48_000, amplitude: 0.1)).verdict, .signal)
    }

    func testTenDBAboveTheFloorReadsHalfLevel() {
        var m = MicLevelMeter()
        m.ingest(steady(48_000, rms: Float(pow(10.0, -60.0 / 20))), sampleRate: rate, channels: 1)
        m.ingest(steady(chunk, rms: Float(pow(10.0, -50.0 / 20))), sampleRate: rate, channels: 1)
        XCTAssertTrue((0.47...0.51).contains(m.level), "level \(m.level)")
    }

    func testFiveChunksFifteenDBAboveTheFloorAreVoiced() {
        var m = MicLevelMeter()
        m.ingest(steady(48_000, rms: Float(pow(10.0, -60.0 / 20))), sampleRate: rate, channels: 1)
        m.ingest(steady(chunk * 5, rms: Float(pow(10.0, -45.0 / 20))), sampleRate: rate, channels: 1)
        XCTAssertEqual(m.voicedChunks, 5)
    }

    func testFiveChunksFiveDBAboveTheFloorAreNotVoiced() {
        var m = MicLevelMeter()
        m.ingest(steady(48_000, rms: Float(pow(10.0, -60.0 / 20))), sampleRate: rate, channels: 1)
        m.ingest(steady(chunk * 5, rms: Float(pow(10.0, -55.0 / 20))), sampleRate: rate, channels: 1)
        XCTAssertEqual(m.voicedChunks, 0)
    }

    func testSixSecondsOfSteadyQuietNoiseIsQuiet() {
        let m = meter(feeding: sine(288_000, amplitude: 0.001 * Float(2).squareRoot()))
        XCTAssertEqual(m.status(elapsed: 6), .quiet)
    }

    func testNonFiniteSamplesGiveFiniteReading() {
        var values: [Float] = []
        for i in 0..<chunk {
            values.append([Float.nan, .infinity, -.infinity, 0.1][i % 4])
        }
        let m = meter(feeding: values)
        XCTAssertEqual(m.chunks, 1)
        XCTAssertTrue(m.lastDB.isFinite)
    }

    func testChunkClockFollowsTheCurrentRate() {
        // First buffer at 48 kHz, then 16 kHz audio: 25 chunks a second, not 8.
        var m = MicLevelMeter()
        m.ingest([], sampleRate: 48_000, channels: 1)
        m.ingest(steady(16_000, rms: 0.1), sampleRate: 16_000, channels: 1)
        XCTAssertEqual(m.chunks, 25)
    }

    func testZeroRateFirstBufferDoesNotMakeEverySampleAChunk() {
        var m = MicLevelMeter()
        m.ingest([], sampleRate: 0, channels: 1)
        m.ingest(steady(48_000, rms: 0.1), sampleRate: 48_000, channels: 1)
        XCTAssertEqual(m.chunks, 25)
    }

    func testNaNRateFirstBufferDoesNotTrap() {
        var m = MicLevelMeter()
        m.ingest([0.1, 0.2], sampleRate: .nan, channels: 1)
        XCTAssertEqual(m.buffers, 1)
        m.ingest(steady(48_000, rms: 0.1), sampleRate: 48_000, channels: 1)
        XCTAssertEqual(m.chunks, 25)
        var report = TakeReport()
        report.record(meter: m)
        _ = report.line
    }

    func testInfiniteRateFirstBufferDoesNotTrap() {
        var m = MicLevelMeter()
        m.ingest([0.1, 0.2], sampleRate: .infinity, channels: 1)
        XCTAssertEqual(m.buffers, 1)
        m.ingest(steady(48_000, rms: 0.1), sampleRate: 48_000, channels: 1)
        XCTAssertEqual(m.chunks, 25)
        var report = TakeReport()
        report.record(meter: m)
        _ = report.line
    }

    /// 500 random signals, cut at random points. The invariants must hold for every one.
    func testGenerativeSignalsKeepTheInvariants() {
        var rng = SplitMix64(state: 0x51C0)
        let amplitudes: [Float] = [0, 1e-7, 0.01, 1, 1e6]
        for _ in 0..<500 {
            var samples: [Float] = []
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let length = Int.random(in: 1...(chunk * 3), using: &rng)
                let amplitude = amplitudes.randomElement(using: &rng)!
                let nanRun = Int.random(in: 0...4, using: &rng) == 0
                for i in 0..<length {
                    if nanRun && Bool.random(using: &rng) {
                        samples.append(.nan)
                    } else {
                        samples.append(amplitude * Float(sin(Double(i) * 0.37)))
                    }
                }
            }
            var m = MicLevelMeter()
            var i = 0
            while i < samples.count {
                let end = min(i + Int.random(in: 1...5000, using: &rng), samples.count)
                m.ingest(Array(samples[i..<end]), sampleRate: rate, channels: 1)
                i = end
            }
            XCTAssertGreaterThanOrEqual(m.level, 0)
            XCTAssertLessThanOrEqual(m.level, 1)
            if let floor = m.floorDB {
                XCTAssertTrue(floor >= -80 && floor <= -50, "floor \(floor) outside -80...-50")
            }
            XCTAssertEqual(m.chunks, samples.count / chunk)
        }
    }
}
