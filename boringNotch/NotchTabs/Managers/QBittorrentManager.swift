//
//  QBittorrentManager.swift
//  boringNotch
//
//  What the seedbox is pulling down, over the qBittorrent WebUI API.
//

import Combine
import Defaults
import Foundation
import Security


/// Polls the qBittorrent WebUI, on the same reference-counted lifecycle as everything else
/// in the notch: `start()`/`stop()`, one stored `Timer`, invalidated at zero watchers, so a
/// closed notch makes no requests.
///
/// The password lives in the Keychain and is read straight into the request body. It is
/// never printed, never put in a URL, and never included in a status message — a failed
/// login says the login failed, not what was tried.
@MainActor
final class QBittorrentManager: ObservableObject {
    static let shared = QBittorrentManager()

    struct Torrent: Identifiable, Equatable {
        let id: String
        let name: String
        let progress: Double
        let downloadBytesPerSec: Double
        let eta: Int
        let state: String
    }

    enum Reachability: Equatable { case unset, probing, ok, needsCredentials, failed(String) }

    @Published private(set) var torrents: [Torrent] = []
    @Published private(set) var totalDownBytesPerSec: Double = 0
    @Published private(set) var state: Reachability = .unset
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastUpdated: Date?

    static let visibleRows = 5
    private static let interval: TimeInterval = 10
    private static let cacheLifetime: TimeInterval = 9
    private static let timeout: TimeInterval = 6
    private static let keychainService = "boringNotch.qbittorrent"

    private var timer: Timer?
    private var watchers = 0
    private var isFetching = false
    /// Set once a login has been accepted, so the common case is one request per tick and
    /// only a rejection costs a second.
    private var isAuthenticated = false

    /// Whether anything has been configured at all, which is a different failure from a
    /// password the WebUI turned down.
    private var hasCredentials: Bool {
        !Defaults[.homelabQbitUsername].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keychainPassword() != nil
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        watchers += 1
        guard timer == nil else { refresh(force: true); return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh(force: true)
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Refresh

    func refresh(force: Bool = false) {
        guard !isFetching else { return }
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.cacheLifetime {
            return
        }
        guard let base = HomelabManager.base(Defaults[.homelabQbitURL]) else {
            state = .unset
            return
        }
        if state == .unset { state = .probing }
        migratePasswordToKeychain()

        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                var list = try await load(from: base)
                if list == nil {
                    // 403: either the session lapsed or there never was one.
                    isAuthenticated = false
                    guard try await login(to: base) else {
                        state = .needsCredentials
                        // "Nothing is set" and "what is set is wrong" are different jobs for
                        // the user, so the panel must not say the same sentence for both.
                        statusMessage = hasCredentials
                            ? "qBittorrent rejected the WebUI username and password"
                            : "Set a qBittorrent WebUI username and password"
                        return
                    }
                    isAuthenticated = true
                    list = try await load(from: base)
                }
                guard let list else {
                    state = .needsCredentials
                    statusMessage = "qBittorrent refused the request even after signing in"
                    return
                }
                if list != torrents { torrents = list }
                totalDownBytesPerSec = list.reduce(0) { $0 + $1.downloadBytesPerSec }
                state = .ok
                statusMessage = ""
                lastUpdated = Date()
            } catch {
                state = .failed(HomelabManager.reason(error))
                statusMessage = HomelabManager.reason(error)
            }
        }
    }

    /// Returns nil for a 403, which is the WebUI's way of saying "sign in first" rather
    /// than an error worth showing anybody.
    private func load(from base: URL) async throws -> [Torrent]? {
        var components = URLComponents(
            url: base.appendingPathComponent("api/v2/torrents/info"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "downloading"),
            URLQueryItem(name: "sort", value: "dlspeed"),
            URLQueryItem(name: "reverse", value: "true"),
            URLQueryItem(name: "limit", value: String(Self.visibleRows)),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 { return nil }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw URLError(.cannotParseResponse) }

        return raw.prefix(Self.visibleRows).compactMap { entry in
            guard let hash = entry["hash"] as? String, let name = entry["name"] as? String
            else { return nil }
            return Torrent(
                id: hash,
                name: name,
                progress: entry["progress"] as? Double ?? 0,
                downloadBytesPerSec: entry["dlspeed"] as? Double ?? 0,
                eta: entry["eta"] as? Int ?? 0,
                state: entry["state"] as? String ?? "")
        }
    }

    /// `POST /api/v2/auth/login`, form encoded. The `Referer` header is not optional
    /// courtesy: qBittorrent's CSRF check rejects a login without one that matches the
    /// WebUI's own address.
    private func login(to base: URL) async throws -> Bool {
        let username = Defaults[.homelabQbitUsername].trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty account is a legitimate configuration — the WebUI can be set to skip
        // authentication for the local subnet — so it is worth one unauthenticated attempt
        // before telling the user to go and set something.
        guard !username.isEmpty, let password = keychainPassword() else { return false }

        var request = URLRequest(url: base.appendingPathComponent("api/v2/auth/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return false }
        // A wrong password is a 200 whose body reads "Fails."; only "Ok." is a session.
        return String(data: data, encoding: .utf8)?.hasPrefix("Ok") ?? false
    }

    // MARK: - Keychain

    private func query(_ username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.keychainService,
         kSecAttrAccount as String: username]
    }

    private func keychainPassword() -> String? {
        let username = Defaults[.homelabQbitUsername]
        var lookup = query(username)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func migratePasswordToKeychain() {
        let password = Defaults[.homelabQbitPassword]
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        let username = Defaults[.homelabQbitUsername]

        SecItemDelete(query(username) as CFDictionary)
        var item = query(username)
        item[kSecValueData as String] = data
        // The notch reads this on a timer while unlocked, so it must survive a locked
        // screen without prompting; it never has to leave this machine.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            Defaults[.homelabQbitPassword] = ""
            isAuthenticated = false
        }
    }
}
