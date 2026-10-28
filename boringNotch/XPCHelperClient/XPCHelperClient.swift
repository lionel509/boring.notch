import Foundation
import Cocoa
import AsyncXPCConnection

final class XPCHelperClient: NSObject {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "theboringteam.boringnotch.BoringNotchXPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    
    deinit {
        connection?.invalidate()
        stopMonitoringAccessibilityAuthorization()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    nonisolated func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        // Ensure only one monitor exists
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // Call the helper method periodically which will notify on change
                _ = await self.isAccessibilityAuthorized()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    nonisolated func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // Expose whether the client is actively monitoring (useful for tests/debug)
    var isMonitoring: Bool {
        return monitoringTask != nil
    }
    
    // MARK: - System

    /// The process behind a CPU alert. `nil` when nothing stands out, or when the helper is
    /// unreachable -- the caller treats both the same way and simply omits the name.
    nonisolated func topProcessName() async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: String? = try await service.withContinuation { service, continuation in
                service.topProcessName { name in
                    continuation.resume(returning: name)
                }
            }
            return result
        } catch {
            return nil
        }
    }

    /// The largest resident process, for a memory surge. `nil` when nothing is big enough to
    /// be worth naming, or when the helper is unreachable.
    nonisolated func topMemoryProcess() async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: String? = try await service.withContinuation { service, continuation in
                service.topMemoryProcess { name in
                    continuation.resume(returning: name)
                }
            }
            return result
        } catch {
            return nil
        }
    }

    /// The whole CPU/memory ranking as JSON, for the Offenders panel. The sandbox returns
    /// nothing for a process list, so this is the only route to one.
    nonisolated func topProcesses(limit: Int = 8) async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.topProcesses(limit) { json in
                    continuation.resume(returning: json)
                }
            }
        } catch {
            return nil
        }
    }

    /// `system_profiler`'s Bluetooth JSON, for the battery levels of classic devices.
    /// CoreBluetooth cannot see those devices at all, and the sandbox cannot spawn the tool.
    nonisolated func bluetoothDevices() async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.bluetoothDevices { json in
                    continuation.resume(returning: json)
                }
            }
        } catch {
            return nil
        }
    }

    /// Runs a whitelisted Tailscale subcommand. The CLI is unreachable from inside the
    /// sandbox, so it runs in the helper and the output comes back as text.
    nonisolated func tailscale(_ subcommand: String) async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.runTailscale(subcommand) { output in
                    continuation.resume(returning: output)
                }
            }
        } catch {
            return nil
        }
    }

    /// What is drawing power, for a drain alert. `nil` when nothing clears the floor or the
    /// helper is unreachable -- the caller omits the name either way.
    nonisolated func topPowerProcess() async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let result: String? = try await service.withContinuation { service, continuation in
                service.topPowerProcess { name in
                    continuation.resume(returning: name)
                }
            }
            return result
        } catch {
            return nil
        }
    }

    // MARK: - Accessibility
    
    nonisolated func requestAccessibilityAuthorization() {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    nonisolated func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    nonisolated func postPasteKeystroke(keyCode: UInt16) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.postPasteKeystroke(Int(keyCode)) { posted in
                    continuation.resume(returning: posted)
                }
            }
            return result
        } catch {
            return false
        }
    }
    
    /// Inserts ghost text into the field the read that issued `token` found. Codes are the helper's (0 inserted,
    /// 2 set failed, 3 unverified, 4 no focus, 5 refused, 6 not trusted, 7 typed fallback, 8 stale token,
    /// 9 not frontmost, 10 focus moved, 11 secure). -1 when the XPC call fails.
    nonisolated func ghostInsert(token: String, location: Int, text: String) async -> Int {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let code: Int = try await service.withContinuation { service, continuation in
                service.ghostInsert(token, location, text) { code in continuation.resume(returning: code) }
            }
            return code
        } catch {
            return -1
        }
    }

    /// Posts back an Option+Tab the app swallowed for an accept that wrote nothing. False when the XPC call fails.
    nonisolated func postGhostAcceptKey() async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let posted: Bool = try await service.withContinuation { service, continuation in
                service.postGhostAcceptKey { posted in continuation.resume(returning: posted) }
            }
            return posted
        } catch {
            return false
        }
    }

    /// The focused text field as JSON, or nil when unavailable. A secure field is never read.
    nonisolated func focusedTextSnapshotJSON() async -> String? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: String? = try await service.withContinuation { service, continuation in
                service.focusedTextSnapshot { json in
                    continuation.resume(returning: json)
                }
            }
            return result
        } catch {
            return nil
        }
    }
    

    // MARK: - Dictation rewrite (U4)

    nonisolated func openRouterKey() async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let key: String? = try await service.withContinuation { service, continuation in
                service.openRouterKey { key in continuation.resume(returning: key) }
            }
            return key
        } catch {
            return nil
        }
    }
    

    nonisolated func focusedTextValue() async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let value: String? = try await service.withContinuation { service, continuation in
                service.focusedTextValue { value in continuation.resume(returning: value) }
            }
            return value
        } catch {
            return nil
        }
    }

    /// Turns on the frontmost app's accessibility tree at press time. True if a focused element now resolves.
    nonisolated func prepareFocus(pid: Int) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let ok: Bool = try await service.withContinuation { service, continuation in
                service.prepareFocus(pid) { ok in continuation.resume(returning: ok) }
            }
            return ok
        } catch {
            return false
        }
    }

    nonisolated func beginTracking() async -> FocusedField? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let json: String? = try await service.withContinuation { service, continuation in
                service.beginTracking { json in continuation.resume(returning: json) }
            }
            guard let json, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(FocusedField.self, from: data)
        } catch {
            return nil
        }
    }

    /// -1 unknown, -2 focus moved or nothing tracked.
    nonisolated func caretLocation() async -> Int {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let caret: Int = try await service.withContinuation { service, continuation in
                service.caretLocation { caret in continuation.resume(returning: caret) }
            }
            return caret
        } catch {
            return -1
        }
    }

    nonisolated func stringForRange(_ location: Int, _ length: Int) async -> String? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let text: String? = try await service.withContinuation { service, continuation in
                service.stringForRange(location, length) { text in continuation.resume(returning: text) }
            }
            return text
        } catch {
            return nil
        }
    }

    /// Swap reply codes as in the helper protocol. 6 when the helper cannot be reached, which changes nothing.
    nonisolated func axReplace(_ location: Int, _ length: Int, _ text: String) async -> Int {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let code: Int = try await service.withContinuation { service, continuation in
                service.axReplace(location, length, text) { code in continuation.resume(returning: code) }
            }
            return code
        } catch {
            return 6
        }
    }

    nonisolated func axSelectThenType(_ location: Int, _ length: Int, _ text: String, caretAfter: Int) async -> Int {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let code: Int = try await service.withContinuation { service, continuation in
                service.axSelectThenType(location, length, text, caretAfter) { code in
                    continuation.resume(returning: code)
                }
            }
            return code
        } catch {
            return 6
        }
    }

    nonisolated func typeSwap(suffixGraphemes: Int, oldGraphemes: Int, text: String) async -> Int {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            let code: Int = try await service.withContinuation { service, continuation in
                service.typeSwap(suffixGraphemes, oldGraphemes, text) { code in continuation.resume(returning: code) }
            }
            return code
        } catch {
            return 6
        }
    }

    nonisolated func endTracking() async {
        let service = await MainActor.run { ensureRemoteService() }
        try? await service.withService { service in
            service.endTracking()
        }
    }

    // MARK: - Keyboard Brightness
    
    nonisolated func isKeyboardBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isKeyboardBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentKeyboardBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness
    
    nonisolated func isScreenBrightnessAvailable() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.isScreenBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    nonisolated func currentScreenBrightness() async -> Float? {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}


