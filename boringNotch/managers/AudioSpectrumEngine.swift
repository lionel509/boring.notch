//
//  AudioSpectrumEngine.swift
//  boringNotch
//
//  Real audio analysis for the music visualizer.
//
//  The visualizer used to fake it -- bar heights were CGFloat.random(). This
//  taps the audio of whichever app is actually playing, runs an FFT over it,
//  and produces log-spaced band magnitudes that follow the music.
//
//  A CoreAudio process tap is used rather than ScreenCaptureKit: it captures a
//  single process instead of the whole system, so the permission it asks for is
//  narrow, and MusicManager already tracks the bundle identifier of the playing
//  app -- exactly the input needed to find the target.
//

import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "AudioSpectrum")

@available(macOS 14.4, *)
final class AudioSpectrumEngine: ObservableObject {
    /// Normalised 0...1 band magnitudes, low frequency first. Main-thread only.
    @Published private(set) var bands: [Float]

    // MARK: Tunables

    private let bandCount: Int
    private let fftSize = 1024
    private let log2n = vDSP_Length(10)   // 2^10 == fftSize

    /// Bars must jump to a transient but fall back gently, or the whole thing
    /// reads as noise rather than as music.
    private let attack: Float = 0.55
    private let decay: Float = 0.10

    /// Musically useful range. Below this is rumble, above it is mostly air.
    private let minHz: Float = 40
    private let maxHz: Float = 16_000

    // MARK: CoreAudio state

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID: UUID?
    private(set) var isRunning = false

    // MARK: Sample plumbing

    /// Written by the realtime audio thread, drained by `refreshTimer`.
    private var ring: UnsafeMutablePointer<Float>
    private var ringWrite = 0
    private var ringLock = os_unfair_lock_s()
    private var sampleRate: Float = 48_000

    private var refreshTimer: DispatchSourceTimer?
    private let analysisQueue = DispatchQueue(label: "theboringteam.boringnotch.spectrum", qos: .userInitiated)

    // MARK: FFT scratch (preallocated -- never allocate on the audio thread)

    private let fft: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]
    private var bandRanges: [(lower: Int, upper: Int)] = []

    // MARK: Lifecycle

    init(bandCount: Int = 4) {
        self.bandCount = bandCount
        self.bands = [Float](repeating: 0, count: bandCount)
        self.smoothed = [Float](repeating: 0, count: bandCount)

        self.ring = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        self.ring.initialize(repeating: 0, count: fftSize)

        self.window = [Float](repeating: 0, count: fftSize)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realPart = [Float](repeating: 0, count: fftSize / 2)
        self.imagPart = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)

        self.fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)

        // Hann window: without it, every bar smears from spectral leakage.
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        rebuildBandRanges()
    }

    deinit {
        stop()
        ring.deallocate()
    }

    // MARK: Public control

    /// Start tapping the audio of `bundleIdentifier`. Safe to call repeatedly.
    func start(bundleIdentifier: String?) {
        guard !isRunning else { return }
        guard let bundleIdentifier,
              let app = NSRunningApplication
                  .runningApplications(withBundleIdentifier: bundleIdentifier).first
        else {
            logger.debug("No running app for \(bundleIdentifier ?? "nil"); spectrum stays idle")
            return
        }

        guard let processObject = processObject(forPID: app.processIdentifier) else {
            logger.debug("No audio process object for pid \(app.processIdentifier)")
            return
        }
        guard installTap(on: processObject) else {
            teardownCoreAudio()
            return
        }

        isRunning = true
        startRefreshTimer()
    }

    func stop() {
        guard isRunning || aggregateID != kAudioObjectUnknown else { return }
        refreshTimer?.cancel()
        refreshTimer = nil
        teardownCoreAudio()
        isRunning = false

        let zeroed = [Float](repeating: 0, count: bandCount)
        smoothed = zeroed
        if Thread.isMainThread {
            bands = zeroed
        } else {
            DispatchQueue.main.async { [weak self] in self?.bands = zeroed }
        }
    }

    // MARK: CoreAudio wiring

    private func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        // CoreAudio hands back a +1 CFStringRef here, so it has to come out
        // through Unmanaged and be released. Writing straight into a `CFString`
        // var forms a raw pointer to an object reference and leaks it.
        address.mSelector = kAudioDevicePropertyDeviceUID
        var unmanagedUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, &unmanagedUID) == noErr,
              let unmanagedUID
        else { return nil }
        let uid = unmanagedUID.takeRetainedValue()

        // Remember the real sample rate so the band edges land on the right bins.
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var rate = Float64(48_000)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &rateSize, &rate) == noErr,
           rate > 0 {
            sampleRate = Float(rate)
            rebuildBandRanges()
        }

        return uid as String
    }

    private func installTap(on processObject: AudioObjectID) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        let uuid = UUID()
        description.uuid = uuid
        description.name = "BoringNotch Spectrum"
        // Private so it never shows up as a selectable input device, and unmuted
        // so tapping does not silence what the user is listening to.
        description.isPrivate = true
        description.muteBehavior = .unmuted
        tapUUID = uuid

        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
              tapID != AudioObjectID(kAudioObjectUnknown)
        else {
            logger.error("AudioHardwareCreateProcessTap failed -- audio-input entitlement or permission missing?")
            return false
        }

        guard let outputUID = defaultOutputDeviceUID() else {
            logger.error("No default output device UID; cannot anchor the aggregate device")
            return false
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BoringNotch Spectrum Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: uuid.uuidString,
            ]],
        ]

        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregateID
        ) == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            logger.error("AudioHardwareCreateAggregateDevice failed")
            return false
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateID, analysisQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        }
        guard status == noErr, let ioProcID else {
            logger.error("AudioDeviceCreateIOProcIDWithBlock failed: \(status)")
            return false
        }

        guard AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            logger.error("AudioDeviceStart failed")
            return false
        }
        return true
    }

    private func teardownCoreAudio() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapUUID = nil
    }

    // MARK: Realtime path

    /// Called on the audio thread. Copies into the ring and returns -- no
    /// allocation, no FFT, and never blocks: a dropped block costs one frame of
    /// animation, a blocked audio thread costs a glitch in what the user hears.
    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        guard os_unfair_lock_trylock(&ringLock) else { return }
        defer { os_unfair_lock_unlock(&ringLock) }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let first = buffers.first, let raw = first.mData else { return }

        let channels = Int(first.mNumberChannels)
        guard channels > 0 else { return }
        let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frameCount > 0 else { return }

        let samples = raw.assumingMemoryBound(to: Float.self)
        for frame in 0 ..< frameCount {
            // Mono mixdown; the visualiser has no use for stereo.
            var sum: Float = 0
            for channel in 0 ..< channels {
                sum += samples[frame * channels + channel]
            }
            ring[ringWrite] = sum / Float(channels)
            ringWrite = (ringWrite + 1) % fftSize
        }
    }

    // MARK: Analysis

    private func startRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        // 30 Hz is enough to read as motion without spending the CPU that a
        // display-linked update would.
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in self?.analyse() }
        timer.resume()
        refreshTimer = timer
    }

    private func analyse() {
        guard let fft else { return }

        // Copy the ring out in order, oldest sample first.
        os_unfair_lock_lock(&ringLock)
        let start = ringWrite
        for i in 0 ..< fftSize {
            windowed[i] = ring[(start + i) % fftSize]
        }
        os_unfair_lock_unlock(&ringLock)

        vDSP.multiply(windowed, window, result: &windowed)

        let half = fftSize / 2
        windowed.withUnsafeBufferPointer { timeDomain in
            timeDomain.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { interleaved in
                realPart.withUnsafeMutableBufferPointer { realBuffer in
                    imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!,
                            imagp: imagBuffer.baseAddress!
                        )
                        // Real signal packed as complex pairs, the standard vDSP idiom.
                        vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
                        fft.transform(input: split, output: &split, direction: .forward)
                        vDSP.absolute(split, result: &magnitudes)
                    }
                }
            }
        }

        // Normalise, then compress: raw magnitudes are far too spiky to look
        // like anything, and loudness is perceived roughly logarithmically.
        let scale = 2.0 / Float(fftSize)
        vDSP.multiply(scale, magnitudes, result: &magnitudes)

        var next = [Float](repeating: 0, count: bandCount)
        for (index, range) in bandRanges.enumerated() where range.lower <= range.upper {
            let slice = magnitudes[range.lower ... range.upper]
            let peak = slice.max() ?? 0
            // ~ -60 dB floor mapped to 0, 0 dB to 1.
            let db = 20 * log10f(max(peak, 1e-7))
            next[index] = min(max((db + 60) / 60, 0), 1)
        }

        for i in 0 ..< bandCount {
            let target = next[i]
            let rate = target > smoothed[i] ? attack : decay
            smoothed[i] += (target - smoothed[i]) * rate
        }

        let published = smoothed
        DispatchQueue.main.async { [weak self] in
            self?.bands = published
        }
    }

    /// Log-spaced band edges. Linear spacing would put almost every bar in the
    /// treble, where music has the least going on.
    private func rebuildBandRanges() {
        let half = fftSize / 2
        let binHz = sampleRate / Float(fftSize)
        let logMin = log10f(minHz)
        let logMax = log10f(maxHz)

        var ranges: [(lower: Int, upper: Int)] = []
        for band in 0 ..< bandCount {
            let lowHz = powf(10, logMin + (logMax - logMin) * Float(band) / Float(bandCount))
            let highHz = powf(10, logMin + (logMax - logMin) * Float(band + 1) / Float(bandCount))
            let lower = min(max(Int(lowHz / binHz), 1), half - 1)
            let upper = min(max(Int(highHz / binHz), lower), half - 1)
            ranges.append((lower: lower, upper: upper))
        }
        bandRanges = ranges
    }
}

// MARK: - Front door

/// Always-available wrapper around the engine.
///
/// The tap needs macOS 14.4, an entitlement, and the user's permission -- any of
/// which can be missing. Rather than leave dead bars on screen when that
/// happens, `isLive` reports whether real audio is driving the bars, and the
/// view keeps the old decorative animation as its fallback.
///
/// Levels arrive by callback rather than `@Published` on purpose: publishing at
/// 30 Hz would invalidate a SwiftUI view 30 times a second, which in this app
/// would trade one CPU runaway for another.
final class SpectrumSource {
    /// Called on the main thread ~30x/second while a tap is live.
    var onBands: (([Float]) -> Void)?

    private(set) var isLive = false

    private var engine: AnyObject?
    private var pollTimer: Timer?
    let bandCount: Int

    init(bandCount: Int = 4) {
        self.bandCount = bandCount
    }

    deinit { stop() }

    func start(bundleIdentifier: String?) {
        guard #available(macOS 14.4, *) else { return }
        guard engine == nil else { return }

        let engine = AudioSpectrumEngine(bandCount: bandCount)
        engine.start(bundleIdentifier: bundleIdentifier)
        guard engine.isRunning else { return }
        self.engine = engine
        isLive = true

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine as? AudioSpectrumEngine else { return }
            self.onBands?(engine.bands)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if #available(macOS 14.4, *), let engine = engine as? AudioSpectrumEngine {
            engine.stop()
        }
        engine = nil
        isLive = false
    }
}
