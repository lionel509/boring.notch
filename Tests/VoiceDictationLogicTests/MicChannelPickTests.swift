import Foundation
import XCTest
@testable import VoiceDictationLogic

/// r5 fix2, bug 1: with voice processing on, the input node reports 9 channels and channel 0 is the
/// processed voice. Averaging all nine drops the voice about 23 dB. The pick decides the mono source.
/// Source-reading tests cover the app side: that the VP tap path uses the pick.
final class MicChannelPickTests: XCTestCase {
    func testVoiceProcessedNineChannelsFeedChannelZero() {
        XCTAssertEqual(MicChannelPick.monoSource(channelCount: 9, voiceProcessing: true), .channel(0))
    }

    func testOneChannelIsPassthroughWithOrWithoutVoiceProcessing() {
        XCTAssertEqual(MicChannelPick.monoSource(channelCount: 1, voiceProcessing: false), .passthrough)
        XCTAssertEqual(MicChannelPick.monoSource(channelCount: 1, voiceProcessing: true), .passthrough)
    }

    /// Without voice processing the existing behaviour stays: the converter downmixes.
    func testTwoChannelsWithoutVoiceProcessingDownmix() {
        XCTAssertEqual(MicChannelPick.monoSource(channelCount: 2, voiceProcessing: false), .downmix)
    }

    func testNineChannelsWithoutVoiceProcessingStillDownmix() {
        XCTAssertEqual(MicChannelPick.monoSource(channelCount: 9, voiceProcessing: false), .downmix)
    }

    private func appSource(_ relative: String) throws -> String {
        // #filePath: <root>/Tests/VoiceDictationLogicTests/MicChannelPickTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The VP tap path (the closure installed on the input node) must consult the pick and feed the
    /// picked mono buffer to the converter and the take buffer, not the raw multi-channel buffer.
    func testVoiceProcessingTapPathUsesTheChannelPick() throws {
        let text = try appSource("boringNotch/Voice/SpeechAnalyzerSession.swift")
        XCTAssertTrue(
            text.contains("MicChannelPick.monoSource("),
            "the tap never asks MicChannelPick which channel to feed, so VP's 9 channels are still averaged")
        let tapStart = try XCTUnwrap(text.range(of: "input.installTap(onBus: 0"), "the tap moved; re-check this test")
        let tapEnd = try XCTUnwrap(text.range(of: "configObserver = NotificationCenter", range: tapStart.upperBound..<text.endIndex))
        let tap = String(text[tapStart.lowerBound..<tapEnd.lowerBound])
        XCTAssertTrue(tap.contains("MicChannelPick.monoSource("), "the pick is not inside the installed tap")
        XCTAssertTrue(tap.contains("takeAudio.ingest(mono)"), "the take buffer still receives the raw multi-channel buffer")
        XCTAssertTrue(tap.contains("converter.convert(to: out, error: &error) { _, outStatus in"), "converter block moved; re-check")
        XCTAssertTrue(tap.contains("return mono"), "the converter still reads the raw buffer, not the picked mono one")
    }
}
