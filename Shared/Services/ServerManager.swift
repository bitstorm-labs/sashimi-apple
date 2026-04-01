import Foundation
import Combine

@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published private(set) var accounts: [ServerAccount] = []
    @Published private(set) var servers: [any MediaServer] = []
    @Published private(set) var isAuthenticated = false
    @Published private(set) var serversReady = false
    @Published var logoutReason: LogoutReason?
    @Published var activeServerId: String? {
        didSet { UserDefaults.standard.set(activeServerId, forKey: "activeServerId") }
    }

    private let accountsKeychainKey = "serverAccounts"

    // MARK: - Convenience Accessors

    /// The currently active server (selected by user toggle)
    var activeServer: (any MediaServer)? {
        if let activeServerId {
            return servers.first { $0.id == activeServerId }
        }
        return servers.first
    }

    /// Alias for backward compat
    var primaryServer: (any MediaServer)? { activeServer }

    var currentUserName: String? {
        if let activeServerId {
            return accounts.first { $0.id == activeServerId }?.userName
        }
        return accounts.first?.userName
    }

    var currentUserId: String? {
        if let activeServerId {
            return accounts.first { $0.id == activeServerId }?.userId
        }
        return accounts.first?.userId
    }

    // MARK: - Init

    private init() {
        let loaded = loadAccounts()
        accounts = loaded
        activeServerId = UserDefaults.standard.string(forKey: "activeServerId")
        // Set authenticated immediately so UI doesn't flash login screen
        isAuthenticated = !loaded.isEmpty

        if loaded.isEmpty {
            migrateFromSessionManager()
            serversReady = true
        } else {
            Task {
                for account in loaded {
                    await createServer(for: account)
                }
                serversReady = true
            }
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
            let client = PlexClient()
            await client.configure(serverURL: account.serverURL, authToken: account.accessToken)
            await client.persistForSync()
            let server = PlexServer(account: account, client: client)
            servers.append(server)
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

    func addPlexServer(token: String, resource: PlexResource) async throws {
        // Use the server-specific access token (not the PIN auth token)
        let serverToken = resource.accessToken ?? token

        // Try connections: remote first (relay/external), then local. 3s timeout each.
        let sortedConnections = resource.connections.sorted { !$0.local && $1.local }
        var workingURL: URL?
        for connection in sortedConnections {
            guard let url = URL(string: connection.uri) else { continue }
            let testClient = PlexClient()
            await testClient.configure(serverURL: url, authToken: serverToken)
            let success = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    (try? await testClient.getLibraries()) != nil
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
            if success {
                workingURL = url
                break
            }
        }

        guard let url = workingURL else {
            throw NSError(
                domain: "ServerManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not connect to any server address"]
            )
        }

        let client = PlexClient()
        await client.configure(serverURL: url, authToken: serverToken)
        await client.persistForSync()

        let account = ServerAccount(
            id: UUID().uuidString,
            serverType: .plex,
            serverURL: url,
            serverName: resource.name,
            userId: "plex",
            userName: "Plex User",
            accessToken: serverToken
        )

        accounts.append(account)
        saveAccounts()

        let server = PlexServer(account: account, client: client)
        servers.append(server)
        isAuthenticated = true
        logoutReason = nil
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

    func server(forId id: String) -> (any MediaServer)? {
        servers.first { $0.id == id }
    }

    func account(forId id: String) -> ServerAccount? {
        accounts.first { $0.id == id }
    }

    // MARK: - Multi-Server Aggregation

    /// Servers to use for content — just the active one if set
    var activeServers: [any MediaServer] {
        if let active = activeServer { return [active] }
        return servers
    }

    func getAllResumeItems(limit: Int = 20) async -> [MediaItem] {
        await withTaskGroup(of: [MediaItem].self) { group in
            for server in activeServers {
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
            for server in activeServers {
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
