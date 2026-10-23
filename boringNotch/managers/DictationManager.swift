//
//  DictationManager.swift
//  boringNotch
//
//  Knows when an app is holding the microphone, so the notch can say so.
//

import AppKit
import Combine
import CoreAudio
import Defaults
import Foundation

/// Reports which app, if any, is currently recording from the microphone.
///
/// This is push-driven, not polled, and that is the whole design. CoreAudio answers one
/// property per process per IPC round trip, so walking the ~40 audio processes and asking
/// each whether its input is running measured **21.8 ms**. At 1 Hz that would be over 2% of
/// a core burned forever to watch something that happens a few times an hour. Property
/// listeners cost nothing until the thing actually changes.
///
/// The scan still exists, but it only runs when something changes, and it runs off the
/// main thread.
@MainActor
final class DictationManager: ObservableObject {
    static let shared = DictationManager()

    /// Every app holding the microphone right now. Call detection reads this; the indicator reads `recordingApp`.
    @Published private(set) var micClients: [MicClient] = []

    /// The app currently recording, by display name. Nil when the mic is idle.
    var recordingApp: String? { CallApps.indicatorName(micClients) }

    var isRecording: Bool { recordingApp != nil }

    private var processListRegistered = false
    private var watchedProcesses: Set<AudioObjectID> = []

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Built fresh at each call site rather than stored. CoreAudio takes the address by
    /// `inout`, and a stored one would be actor-isolated to the main thread while the scans
    /// deliberately run off it.
    private nonisolated static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !processListRegistered else { return }

        var listAddress = Self.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(
            Self.systemObject, &listAddress, DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }

        processListRegistered = status == noErr
        Defaults[.dictationDiagnostic] = processListRegistered
            ? "watching the microphone"
            : "could not watch audio processes - OSStatus \(status)"

        refresh()
    }

    // MARK: - Scanning

    /// Rebuilds the per-process listeners and recomputes who is recording.
    ///
    /// A process already in the list flips `IsRunningInput` without the list itself
    /// changing - which is exactly what an always-resident dictation app does when it
    /// starts listening - so every process needs its own listener too.
    private func refresh() {
        Task.detached(priority: .utility) {
            let processes = Self.processObjects()
            let clients = Self.micClients(among: processes)

            await MainActor.run {
                self.registerInputListeners(for: processes)
                if self.micClients != clients { self.micClients = clients }
            }
        }
    }

    private func registerInputListeners(for processes: [AudioObjectID]) {
        for process in processes where !watchedProcesses.contains(process) {
            var inputAddress = Self.address(kAudioProcessPropertyIsRunningInput)
            let status = AudioObjectAddPropertyListenerBlock(
                process, &inputAddress, DispatchQueue.main
            ) { [weak self] _, _ in
                Task { @MainActor in self?.refreshRecordingOnly() }
            }
            if status == noErr { watchedProcesses.insert(process) }
        }
        // A process that has gone away cannot be unregistered - the object is already
        // invalid - so just stop tracking it.
        watchedProcesses.formIntersection(processes)
    }

    /// The cheap half: who is recording, without touching listener registration.
    private func refreshRecordingOnly() {
        Task.detached(priority: .utility) {
            let clients = Self.micClients(among: Self.processObjects())
            await MainActor.run {
                if self.micClients != clients { self.micClients = clients }
            }
        }
    }

    // MARK: - CoreAudio

    private nonisolated static func processObjects() -> [AudioObjectID] {
        var address = self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private nonisolated static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = self.address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private nonisolated static func pid(of process: AudioObjectID) -> pid_t {
        var address = self.address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr
        else { return -1 }
        return value
    }

    /// Every process holding the microphone, in process-list order.
    ///
    /// Processes with no bundle identifier are skipped, which is not a shortcut:
    /// `corespeechd` - the "Hey Siri" daemon - holds the microphone open permanently, so
    /// counting it would leave the indicator lit forever, telling you nothing. A client
    /// with no `name` is kept for call detection but never named by the indicator.
    private nonisolated static func micClients(among processes: [AudioObjectID]) -> [MicClient] {
        var clients: [MicClient] = []
        for process in processes where isRunningInput(process) {
            let processID = pid(of: process)
            guard processID > 0 else { continue }
            let app = NSRunningApplication(processIdentifier: processID)
            guard let identifier = app?.bundleIdentifier ?? coreAudioBundleID(process),
                  !identifier.isEmpty,
                  // Not us. The spectrum's own process tap counts as an input stream, so
                  // the notch would light up to announce that the notch is listening --
                  // every time music plays, which is exactly when nobody is recording.
                  identifier != Bundle.main.bundleIdentifier,
                  app?.bundleIdentifier != Bundle.main.bundleIdentifier
            else { continue }
            // Named only when the indicator always could name it: a running app with a bundle and a name.
            let name = app?.bundleIdentifier == nil ? nil : app?.localizedName.map(friendlyName)
            clients.append(MicClient(bundleID: identifier, pid: processID, name: name))
        }
        return clients
    }

    /// The bundle identifier CoreAudio reports for a process. Covers the processes with no
    /// `NSRunningApplication` (FaceTime's `avconferenced`, for one).
    private nonisolated static func coreAudioBundleID(_ process: AudioObjectID) -> String? {
        var address = self.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let cfValue = value
        else { return nil }
        let identifier = cfValue.takeRetainedValue() as String
        return identifier.isEmpty ? nil : identifier
    }

    /// Electron apps record from a helper process, whose name is the app's plus a suffix
    /// nobody wants to read in a notch.
    private nonisolated static func friendlyName(_ name: String) -> String {
        for marker in [" Helper", " (Renderer)", " (GPU)"] {
            if let range = name.range(of: marker) {
                return String(name[..<range.lowerBound])
            }
        }
        return name
    }
}

import SwiftUI

/// Three dots breathing in sequence: enough to read as "live" without a timer.
///
/// Driven by Core Animation through a repeating SwiftUI animation rather than by a
/// `Timer`, so nothing has to be invalidated and nothing keeps running once the view goes
/// away. A leaked repeating timer is how this app once reached 31.7% CPU.
struct ListeningDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.red.opacity(0.85))
                    .frame(width: 3.5, height: 3.5)
                    .scaleEffect(animating ? 1 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: animating)
            }
        }
        .onAppear { animating = true }
    }
}
