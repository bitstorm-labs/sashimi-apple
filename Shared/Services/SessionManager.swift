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

    var errorDescription: String? {
        switch self {
        case .credentialStorageFailed:
            return "Could not save credentials securely. Please try signing in again."
        }
    }
}

@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: UserDto?
    @Published private(set) var serverURL: URL?
    @Published var logoutReason: LogoutReason?

    private let userDefaultsServerURLKey = "serverURL"
    private let userDefaultsUserIdKey = "userId"
    private let keychainAccessTokenKey = "accessToken"
    /// Pre-Keychain builds stored the token in plaintext under this key.
    private let legacyUserDefaultsTokenKey = "accessToken"

    private init() {
        Task {
            await restoreSession()
        }
    }

    func restoreSession() async {
        guard let urlString = UserDefaults.standard.string(forKey: userDefaultsServerURLKey),
              let url = URL(string: urlString),
              let accessToken = KeychainHelper.get(forKey: keychainAccessTokenKey),
              let userId = UserDefaults.standard.string(forKey: userDefaultsUserIdKey) else {
            // Migration: Check if token exists in UserDefaults (legacy) and migrate to Keychain
            if let legacyToken = UserDefaults.standard.string(forKey: legacyUserDefaultsTokenKey) {
                if KeychainHelper.save(legacyToken, forKey: keychainAccessTokenKey) {
                    UserDefaults.standard.removeObject(forKey: legacyUserDefaultsTokenKey)
                    await restoreSession()
                } else {
                    // Keep the legacy token in UserDefaults so migration can
                    // retry next launch; removing it after a failed save would
                    // silently sign the user out.
                    logger.error("Keychain save failed while migrating legacy token; will retry next launch")
                }
            }
            return
        }

        // Scrub the legacy plaintext copy unconditionally: if the process died
        // between the migration's Keychain save and its UserDefaults cleanup,
        // the migration branch above never re-runs (the Keychain read now
        // succeeds), which would strand the plaintext token forever.
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsTokenKey)

        await JellyfinClient.shared.configure(serverURL: url, accessToken: accessToken, userId: userId)
        self.serverURL = url
        self.currentUser = UserDto(id: userId, name: UserDefaults.standard.string(forKey: "userName") ?? "User", serverID: nil, primaryImageTag: nil)
        self.isAuthenticated = true
    }

    func login(serverURL: URL, username: String, password: String) async throws {
        await JellyfinClient.shared.configure(serverURL: serverURL)

        let result = try await JellyfinClient.shared.authenticate(username: username, password: password)

        // Persist the token first: if the Keychain rejects it, fail the login
        // visibly rather than leaving a session that vanishes on next launch.
        guard KeychainHelper.save(result.accessToken, forKey: keychainAccessTokenKey) else {
            logger.error("Keychain save for access token failed during login")
            // authenticate() already stored the token/userId inside the
            // client; clear them so the client isn't left "logged in" while
            // this SessionManager reports signed-out.
            await JellyfinClient.shared.clearCredentials()
            throw SessionError.credentialStorageFailed
        }

        UserDefaults.standard.set(serverURL.absoluteString, forKey: userDefaultsServerURLKey)
        UserDefaults.standard.set(result.user.id, forKey: userDefaultsUserIdKey)
        UserDefaults.standard.set(result.user.name, forKey: "userName")

        self.serverURL = serverURL
        self.currentUser = result.user
        self.logoutReason = nil
        self.isAuthenticated = true
    }

    func logout(reason: LogoutReason = .userInitiated) {
        UserDefaults.standard.removeObject(forKey: userDefaultsServerURLKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsUserIdKey)
        // Also drop any lingering pre-Keychain plaintext token.
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsTokenKey)
        KeychainHelper.delete(forKey: keychainAccessTokenKey)

        Task { await JellyfinClient.shared.clearCredentials() }

        self.serverURL = nil
        self.currentUser = nil
        self.logoutReason = reason
        self.isAuthenticated = false
    }
}
