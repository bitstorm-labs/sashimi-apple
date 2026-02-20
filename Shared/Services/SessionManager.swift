import Foundation
import Combine

enum LogoutReason {
    case userInitiated
    case sessionExpired
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
            if let legacyToken = UserDefaults.standard.string(forKey: "accessToken") {
                KeychainHelper.save(legacyToken, forKey: keychainAccessTokenKey)
                UserDefaults.standard.removeObject(forKey: "accessToken")
                await restoreSession()
            }
            return
        }

        await JellyfinClient.shared.configure(serverURL: url, accessToken: accessToken, userId: userId)
        self.serverURL = url
        self.currentUser = UserDto(id: userId, name: UserDefaults.standard.string(forKey: "userName") ?? "User", serverID: nil, primaryImageTag: nil)
        self.isAuthenticated = true
    }

    func login(serverURL: URL, username: String, password: String) async throws {
        await JellyfinClient.shared.configure(serverURL: serverURL)

        let result = try await JellyfinClient.shared.authenticate(username: username, password: password)

        UserDefaults.standard.set(serverURL.absoluteString, forKey: userDefaultsServerURLKey)
        KeychainHelper.save(result.accessToken, forKey: keychainAccessTokenKey)
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
        KeychainHelper.delete(forKey: keychainAccessTokenKey)

        self.serverURL = nil
        self.currentUser = nil
        self.logoutReason = reason
        self.isAuthenticated = false
    }

    func clearLogoutReason() {
        logoutReason = nil
    }
}
