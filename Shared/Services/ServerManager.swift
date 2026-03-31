import Foundation
import Combine

@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published private(set) var accounts: [ServerAccount] = []
    @Published private(set) var servers: [any MediaServer] = []
    @Published private(set) var isAuthenticated = false
    @Published var logoutReason: LogoutReason?

    private let accountsKeychainKey = "serverAccounts"

    // MARK: - Convenience Accessors

    var primaryServer: (any MediaServer)? {
        servers.first
    }

    var currentUserName: String? {
        accounts.first?.userName
    }

    var currentUserId: String? {
        accounts.first?.userId
    }

    // MARK: - Init

    private init() {
        let loaded = loadAccounts()
        accounts = loaded
        Task {
            for account in loaded {
                await createServer(for: account)
            }
            isAuthenticated = !servers.isEmpty
        }

        // Migration: if no accounts in Keychain, check for old SessionManager credentials
        if loaded.isEmpty {
            migrateFromSessionManager()
        }
    }

    // MARK: - Persistence

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        KeychainHelper.saveData(data, forKey: accountsKeychainKey)
    }

    private func loadAccounts() -> [ServerAccount] {
        guard let data = KeychainHelper.getData(forKey: accountsKeychainKey),
              let decoded = try? JSONDecoder().decode([ServerAccount].self, from: data) else {
            return []
        }
        return decoded
    }

    // MARK: - Migration

    private func migrateFromSessionManager() {
        guard let urlString = UserDefaults.standard.string(forKey: "serverURL"),
              let url = URL(string: urlString),
              let accessToken = KeychainHelper.get(forKey: "accessToken"),
              let userId = UserDefaults.standard.string(forKey: "userId") else {
            return
        }

        let userName = UserDefaults.standard.string(forKey: "userName") ?? "User"

        let account = ServerAccount(
            id: UUID().uuidString,
            serverType: .jellyfin,
            serverURL: url,
            serverName: url.host ?? "Jellyfin Server",
            userId: userId,
            userName: userName,
            accessToken: accessToken
        )

        accounts = [account]
        saveAccounts()

        Task {
            await createServer(for: account)
            isAuthenticated = !servers.isEmpty
        }
    }

    // MARK: - Server Lifecycle

    private func createServer(for account: ServerAccount) async {
        switch account.serverType {
        case .jellyfin:
            let client = JellyfinClient.shared
            await client.configure(
                serverURL: account.serverURL,
                accessToken: account.accessToken,
                userId: account.userId
            )
            let server = JellyfinServer(account: account, client: client)
            servers.append(server)
        case .plex:
            break // Not yet supported
        }
    }

    func addJellyfinServer(url: URL, username: String, password: String) async throws {
        let client = JellyfinClient.shared
        await client.configure(serverURL: url)
        let result = try await client.authenticate(username: username, password: password)

        let account = ServerAccount(
            id: UUID().uuidString,
            serverType: .jellyfin,
            serverURL: url,
            serverName: url.host ?? "Jellyfin Server",
            userId: result.user.id,
            userName: result.user.name ?? username,
            accessToken: result.accessToken
        )

        accounts.append(account)
        saveAccounts()

        let server = JellyfinServer(account: account, client: client)
        servers.append(server)

        logoutReason = nil
        isAuthenticated = true
    }

    func removeServer(id: String) {
        accounts.removeAll { $0.id == id }
        servers.removeAll { $0.id == id }
        saveAccounts()
        isAuthenticated = !accounts.isEmpty
    }

    func logout(reason: LogoutReason = .userInitiated) {
        accounts.removeAll()
        servers.removeAll()
        KeychainHelper.delete(forKey: accountsKeychainKey)
        logoutReason = reason
        isAuthenticated = false
    }

    // MARK: - Server Lookup

    func server(for item: MediaItem) -> (any MediaServer)? {
        servers.first { $0.id == item.serverId }
    }

    // MARK: - Multi-Server Aggregation

    func getAllResumeItems(limit: Int = 20) async -> [MediaItem] {
        await withTaskGroup(of: [MediaItem].self) { group in
            for server in servers {
                group.addTask {
                    (try? await server.getResumeItems(limit: limit)) ?? []
                }
            }
            var results: [MediaItem] = []
            for await items in group {
                results.append(contentsOf: items)
            }
            return results
        }
    }

    func getAllNextUp(limit: Int = 50) async -> [MediaItem] {
        await withTaskGroup(of: [MediaItem].self) { group in
            for server in servers {
                group.addTask {
                    (try? await server.getNextUp(limit: limit)) ?? []
                }
            }
            var results: [MediaItem] = []
            for await items in group {
                results.append(contentsOf: items)
            }
            return results
        }
    }

    func clearLogoutReason() {
        logoutReason = nil
    }
}
