import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.sashimi.app", category: "SessionManager")

enum LogoutReason {
    case userInitiated
    case sessionExpired
}

enum SessionError: LocalizedError {
    /// The Keychain rejected the access token write. Login is aborted so the
    /// user sees the failure now instead of being silently signed out on the
    /// next launch (restoreSession requires the token to be in the Keychain).
    case credentialStorageFailed
    /// Same server URL + user already saved.
    case duplicateServer

    var errorDescription: String? {
        switch self {
        case .credentialStorageFailed:
            return "Could not save credentials securely. Please try signing in again."
        case .duplicateServer:
            return "That server and user are already added."
        }
    }
}

/// A saved Jellyfin server + account. Tokens live in the Keychain under
/// "accessToken.<id>"; everything else persists as JSON in UserDefaults.
struct ServerConfig: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let url: URL
    let username: String
    let userId: String
}

@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: UserDto?
    @Published private(set) var serverURL: URL?
    @Published private(set) var servers: [ServerConfig] = []
    @Published private(set) var activeServerId: String?
    @Published var logoutReason: LogoutReason?

    private let serversKey = "servers"
    private let activeServerIdKey = "activeServerId"

    // Legacy single-server keys (pre multi-server)
    private let userDefaultsServerURLKey = "serverURL"
    private let userDefaultsUserIdKey = "userId"
    private let keychainAccessTokenKey = "accessToken"
    /// Pre-Keychain builds stored the token in plaintext under this key.
    private let legacyUserDefaultsTokenKey = "accessToken"

    var activeServer: ServerConfig? {
        servers.first(where: { $0.id == activeServerId })
    }

    private init() {
        Task {
            await restoreSession()
        }
    }

    // MARK: - Persistence

    private func loadServers() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let list = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = list
        }
        activeServerId = UserDefaults.standard.string(forKey: activeServerIdKey)
    }

    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
        UserDefaults.standard.set(activeServerId, forKey: activeServerIdKey)
    }

    private func tokenKey(_ id: String) -> String { "accessToken.\(id)" }

    // MARK: - Session lifecycle

    func restoreSession() async {
        loadServers()

        // Migrate the legacy single-server session into the list once.
        if servers.isEmpty {
            migrateLegacySession()
        }

        guard let server = activeServer ?? servers.first,
              let token = KeychainHelper.get(forKey: tokenKey(server.id)) else {
            return
        }
        if activeServerId != server.id {
            activeServerId = server.id
            saveServers()
        }
        await activate(server, token: token)
    }

    /// Pre multi-server builds stored one server across three UserDefaults
    /// keys + one Keychain entry (with an even older plaintext fallback).
    private func migrateLegacySession() {
        guard let urlString = UserDefaults.standard.string(forKey: userDefaultsServerURLKey),
              let url = URL(string: urlString),
              let userId = UserDefaults.standard.string(forKey: userDefaultsUserIdKey) else { return }

        var token = KeychainHelper.get(forKey: keychainAccessTokenKey)
        if token == nil, let legacy = UserDefaults.standard.string(forKey: legacyUserDefaultsTokenKey) {
            token = legacy
        }
        guard let token else { return }

        let config = ServerConfig(
            id: UUID().uuidString,
            name: url.host ?? "Jellyfin",
            url: url,
            username: UserDefaults.standard.string(forKey: "userName") ?? "User",
            userId: userId
        )
        guard KeychainHelper.save(token, forKey: tokenKey(config.id)) else {
            logger.error("Keychain save failed while migrating legacy session; will retry next launch")
            return
        }
        servers = [config]
        activeServerId = config.id
        saveServers()

        // Scrub every legacy copy only after the new entry is durable.
        UserDefaults.standard.removeObject(forKey: userDefaultsServerURLKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsUserIdKey)
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsTokenKey)
        KeychainHelper.delete(forKey: keychainAccessTokenKey)
        logger.info("Migrated legacy single-server session to multi-server store")
    }

    private func activate(_ server: ServerConfig, token: String) async {
        await JellyfinClient.shared.configure(serverURL: server.url, accessToken: token, userId: server.userId)
        self.serverURL = server.url
        self.currentUser = UserDto(id: server.userId, name: server.username, serverID: nil, primaryImageTag: nil)
        self.isAuthenticated = true
    }

    // MARK: - Add / switch / remove

    /// Signs into a server and ADDS it to the saved list (making it active).
    func login(serverURL: URL, username: String, password: String) async throws {
        await JellyfinClient.shared.configure(serverURL: serverURL)

        let result = try await JellyfinClient.shared.authenticate(username: username, password: password)

        if servers.contains(where: { $0.url == serverURL && $0.userId == result.user.id }) {
            // Restore the previously active server's client config.
            if let current = activeServer, let token = KeychainHelper.get(forKey: tokenKey(current.id)) {
                await activate(current, token: token)
            }
            throw SessionError.duplicateServer
        }

        var serverName = serverURL.host ?? "Jellyfin"
        if let info = try? await JellyfinClient.shared.getPublicSystemInfo(), let name = info.serverName {
            serverName = name
        }

        let config = ServerConfig(
            id: UUID().uuidString,
            name: serverName,
            url: serverURL,
            username: result.user.name ?? username,
            userId: result.user.id
        )

        // Persist the token first: if the Keychain rejects it, fail the login
        // visibly rather than leaving a session that vanishes on next launch.
        guard KeychainHelper.save(result.accessToken, forKey: tokenKey(config.id)) else {
            logger.error("Keychain save for access token failed during login")
            await JellyfinClient.shared.clearCredentials()
            throw SessionError.credentialStorageFailed
        }

        servers.append(config)
        activeServerId = config.id
        saveServers()

        self.serverURL = serverURL
        self.currentUser = result.user
        self.logoutReason = nil
        self.isAuthenticated = true
    }

    /// Switch the active server (no-op if already active or unknown).
    func switchServer(to id: String) async {
        guard id != activeServerId,
              let server = servers.first(where: { $0.id == id }),
              let token = KeychainHelper.get(forKey: tokenKey(server.id)) else { return }
        activeServerId = id
        saveServers()
        await activate(server, token: token)
    }

    /// Remove a saved server. Removing the active one activates the next;
    /// removing the last returns to the signed-out state.
    func removeServer(id: String) async {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        KeychainHelper.delete(forKey: tokenKey(id))
        servers.remove(at: idx)

        if activeServerId == id {
            if let next = servers.first, let token = KeychainHelper.get(forKey: tokenKey(next.id)) {
                activeServerId = next.id
                saveServers()
                await activate(next, token: token)
            } else {
                activeServerId = nil
                saveServers()
                Task { await JellyfinClient.shared.clearCredentials() }
                self.serverURL = nil
                self.currentUser = nil
                self.logoutReason = .userInitiated
                self.isAuthenticated = false
            }
        } else {
            saveServers()
        }
    }

    /// Sign out of the ACTIVE server (removes it from the list). A session
    /// expiry keeps the entry so the user can re-authenticate; it just
    /// drops to signed-out state.
    func logout(reason: LogoutReason = .userInitiated) {
        if let active = activeServerId {
            if reason == .sessionExpired {
                // Keep the entry so the user can re-authenticate; just drop
                // the dead token and session state.
                KeychainHelper.delete(forKey: tokenKey(active))
            } else {
                Task { await removeServer(id: active) }
            }
        }
        Task { await JellyfinClient.shared.clearCredentials() }
        self.serverURL = nil
        self.currentUser = nil
        self.logoutReason = reason
        self.isAuthenticated = false
    }
}
