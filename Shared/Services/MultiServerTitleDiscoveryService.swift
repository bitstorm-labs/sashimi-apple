import Foundation

/// The read-only Jellyfin operations needed by title discovery.
///
/// Keeping this seam separate from the App Intents types lets the same
/// server-selection and partial-failure behavior be tested without real
/// servers. JellyfinClient remains the production implementation.
protocol SashimiTitleDiscoveryClient: Sendable {
    func search(query: String, limit: Int) async throws -> [BaseItemDto]
    func getLatestMedia(
        parentId: String?,
        limit: Int,
        includeWatched: Bool,
        collectionType: String?,
        groupItems: Bool
    ) async throws -> [BaseItemDto]
}

extension JellyfinClient: SashimiTitleDiscoveryClient {}

enum MultiServerTitleDiscoveryError: LocalizedError, Equatable, Sendable {
    case noAvailableServerSessions
    case allServersUnavailable
    case serverNotFound
    case serverAuthenticationRequired
    case defaultServerUnavailable

    var errorDescription: String? {
        switch self {
        case .noAvailableServerSessions:
            return "No signed-in Sashimi servers are available."
        case .allServersUnavailable:
            return "Sashimi could not reach any signed-in server."
        case .serverNotFound:
            return "That Sashimi server is no longer configured."
        case .serverAuthenticationRequired:
            return "Sign in to that Sashimi server before using it."
        case .defaultServerUnavailable:
            return "Sashimi's default server is no longer available."
        }
    }
}

private func multiServerTitleDiscoveryFailure(
    for error: JellyfinError
) -> MultiServerTitleDiscoveryFailure {
    switch error {
    case .invalidCredentials, .sessionExpired:
        return .authenticationRequired
    case .httpError(let statusCode) where statusCode == 401:
        return .authenticationRequired
    default:
        return .unavailable
    }
}

enum MultiServerTitleDiscoveryFailure: Sendable, Equatable {
    case unavailable
    case authenticationRequired
}

struct MultiServerTitleDiscoveryServerResult: Sendable {
    let serverIndex: Int
    let items: [ServerMediaResult]
    let succeeded: Bool
    let failure: MultiServerTitleDiscoveryFailure?

    init(
        serverIndex: Int,
        items: [ServerMediaResult],
        succeeded: Bool,
        failure: MultiServerTitleDiscoveryFailure? = nil
    ) {
        self.serverIndex = serverIndex
        self.items = items
        self.succeeded = succeeded
        self.failure = failure
    }
}

enum MultiServerTitleDiscoveryService {
    typealias TokenProvider = @Sendable (ServerConfig) async -> String?
    typealias ClientFactory = @Sendable (ServerConfig, String) async -> any SashimiTitleDiscoveryClient

    static let defaultResultLimit = 10
    static let maximumResultLimit = 50

    /// Searches every authenticated saved server unless a server ID is
    /// supplied as an explicit Shortcuts override. Results are interleaved by
    /// server before the aggregate limit is applied so a single server cannot
    /// crowd every other authenticated server out of a bounded result set.
    static func search(
        query: String,
        limit: Int,
        serverID: String? = nil,
        servers suppliedServers: [ServerConfig]? = nil,
        tokenProvider suppliedTokenProvider: TokenProvider? = nil,
        clientFactory suppliedClientFactory: ClientFactory? = nil
    ) async throws -> [ServerMediaResult] {
        let servers = await savedServers(suppliedServers)
        let selectedServers = try selectServers(
            from: servers,
            serverID: serverID,
            missingServerError: .serverNotFound
        )
        let requestLimit = boundedLimit(limit)
        let load = try await loadResults(
            from: selectedServers,
            operation: .search(query: query, limit: requestLimit),
            tokenProvider: suppliedTokenProvider,
            clientFactory: suppliedClientFactory,
            missingTokenError: serverID == nil ? nil : .serverAuthenticationRequired
        )
        try ensureUsableResponses(load.responses, attemptedServerCount: load.attemptedServerCount)

        return interleavedResults(
            from: load.responses,
            limit: requestLimit
        )
    }

    /// Loads content-added titles from the persisted default server unless a
    /// server ID is supplied as an explicit Shortcuts override. The request
    /// uses Jellyfin's DateCreated/SortName ordering through getLatestMedia's
    /// include-watched path; it does not consult resume or recently-watched
    /// state.
    static func recentlyAdded(
        limit: Int,
        serverID suppliedServerID: String? = nil,
        servers suppliedServers: [ServerConfig]? = nil,
        defaultServerID suppliedDefaultServerID: String? = nil,
        tokenProvider suppliedTokenProvider: TokenProvider? = nil,
        clientFactory suppliedClientFactory: ClientFactory? = nil
    ) async throws -> [ServerMediaResult] {
        let servers = await savedServers(suppliedServers)
        let serverID: String
        let missingServerError: MultiServerTitleDiscoveryError

        if let suppliedServerID {
            serverID = suppliedServerID
            missingServerError = .serverNotFound
        } else {
            guard let defaultServerID = await defaultServerID(suppliedDefaultServerID) else {
                throw MultiServerTitleDiscoveryError.defaultServerUnavailable
            }
            serverID = defaultServerID
            missingServerError = .defaultServerUnavailable
        }

        let selectedServers = try selectServers(
            from: servers,
            serverID: serverID,
            missingServerError: missingServerError
        )
        let requestLimit = boundedLimit(limit)
        let load = try await loadResults(
            from: selectedServers,
            operation: .recentlyAdded(limit: requestLimit),
            tokenProvider: suppliedTokenProvider,
            clientFactory: suppliedClientFactory,
            missingTokenError: .serverAuthenticationRequired
        )
        try ensureUsableResponses(load.responses, attemptedServerCount: load.attemptedServerCount)

        return load.responses
            .sorted { $0.serverIndex < $1.serverIndex }
            .flatMap(\.items)
            .prefix(requestLimit)
            .map { $0 }
    }

    static func boundedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), maximumResultLimit)
    }

    /// Aggregates partial server responses while turning an all-server outage
    /// into an actionable error. A successful server with zero matches is a
    /// valid empty result and is intentionally not treated as an outage.
    static func aggregate(
        _ responses: [MultiServerTitleDiscoveryServerResult],
        attemptedServerCount: Int
    ) throws -> [ServerMediaResult] {
        try ensureUsableResponses(responses, attemptedServerCount: attemptedServerCount)
        return responses
            .sorted { $0.serverIndex < $1.serverIndex }
            .flatMap(\.items)
    }

    private enum Operation: Sendable {
        case search(query: String, limit: Int)
        case recentlyAdded(limit: Int)
    }

    private struct LoadResult {
        let responses: [MultiServerTitleDiscoveryServerResult]
        let attemptedServerCount: Int
    }

    private struct AuthenticatedServerRequest {
        let serverIndex: Int
        let server: ServerConfig
        let token: String
    }

    private static func savedServers(_ suppliedServers: [ServerConfig]?) async -> [ServerConfig] {
        if let suppliedServers {
            return suppliedServers
        }
        return await MainActor.run { SessionManager.shared.servers }
    }

    private static func defaultServerID(_ suppliedServerID: String?) async -> String? {
        if let suppliedServerID {
            return suppliedServerID
        }
        return await MainActor.run { SessionManager.shared.defaultServerId }
    }

    private static func selectServers(
        from servers: [ServerConfig],
        serverID: String?,
        missingServerError: MultiServerTitleDiscoveryError
    ) throws -> [ServerConfig] {
        guard let serverID else {
            return servers
        }
        guard let server = servers.first(where: { $0.id == serverID }) else {
            throw missingServerError
        }
        return [server]
    }

    private static func loadResults(
        from servers: [ServerConfig],
        operation: Operation,
        tokenProvider suppliedTokenProvider: TokenProvider?,
        clientFactory suppliedClientFactory: ClientFactory?,
        missingTokenError: MultiServerTitleDiscoveryError?
    ) async throws -> LoadResult {
        let tokenProvider = suppliedTokenProvider ?? { server in
            await MainActor.run {
                SessionManager.shared.token(for: server, allowLegacyFallback: true)
            }
        }
        let clientFactory = suppliedClientFactory ?? { server, token in
            let client = JellyfinClient()
            await client.configure(serverURL: server.url, accessToken: token, userId: server.userId)
            return client
        }
        let requests = try await authenticatedServerRequests(
            from: servers,
            tokenProvider: tokenProvider,
            missingTokenError: missingTokenError
        )

        let responses = await withTaskGroup(
            of: MultiServerTitleDiscoveryServerResult.self,
            returning: [MultiServerTitleDiscoveryServerResult].self
        ) { group in
            for request in requests {
                group.addTask {
                    await loadServerResult(
                        serverIndex: request.serverIndex,
                        server: request.server,
                        token: request.token,
                        operation: operation,
                        clientFactory: clientFactory
                    )
                }
            }

            return await group.reduce(into: []) { results, response in
                results.append(response)
            }
        }

        try Task.checkCancellation()
        return LoadResult(
            responses: responses,
            attemptedServerCount: requests.count
        )
    }

    private static func authenticatedServerRequests(
        from servers: [ServerConfig],
        tokenProvider: @escaping TokenProvider,
        missingTokenError: MultiServerTitleDiscoveryError?
    ) async throws -> [AuthenticatedServerRequest] {
        var requests: [AuthenticatedServerRequest] = []
        for (serverIndex, server) in servers.enumerated() {
            let token = await tokenProvider(server)
            guard let token else {
                if let missingTokenError {
                    throw missingTokenError
                }
                continue
            }
            requests.append(
                AuthenticatedServerRequest(
                    serverIndex: serverIndex,
                    server: server,
                    token: token
                )
            )
        }
        try Task.checkCancellation()
        return requests
    }

    private static func loadServerResult(
        serverIndex: Int,
        server: ServerConfig,
        token: String,
        operation: Operation,
        clientFactory: @escaping ClientFactory
    ) async -> MultiServerTitleDiscoveryServerResult {
        do {
            let client = await clientFactory(server, token)
            let items = try await loadItems(operation: operation, client: client)
            return MultiServerTitleDiscoveryServerResult(
                serverIndex: serverIndex,
                items: items.map {
                    ServerMediaResult(
                        item: $0,
                        serverID: server.id,
                        serverName: server.displayName,
                        serverURL: server.url
                    )
                },
                succeeded: true
            )
        } catch is CancellationError {
            return MultiServerTitleDiscoveryServerResult(
                serverIndex: serverIndex,
                items: [],
                succeeded: false
            )
        } catch let error as JellyfinError {
            return MultiServerTitleDiscoveryServerResult(
                serverIndex: serverIndex,
                items: [],
                succeeded: false,
                failure: multiServerTitleDiscoveryFailure(for: error)
            )
        } catch {
            return MultiServerTitleDiscoveryServerResult(
                serverIndex: serverIndex,
                items: [],
                succeeded: false,
                failure: .unavailable
            )
        }
    }

    private static func loadItems(
        operation: Operation,
        client: any SashimiTitleDiscoveryClient
    ) async throws -> [BaseItemDto] {
        switch operation {
        case .search(let query, let limit):
            return try await client.search(query: query, limit: limit)
        case .recentlyAdded(let limit):
            // This path is sorted by content-created time, not resume or
            // recently-watched state.
            return try await client.getLatestMedia(
                parentId: nil,
                limit: limit,
                includeWatched: true,
                collectionType: nil,
                groupItems: true
            )
        }
    }

    private static func ensureUsableResponses(
        _ responses: [MultiServerTitleDiscoveryServerResult],
        attemptedServerCount: Int
    ) throws {
        guard attemptedServerCount > 0 else {
            throw MultiServerTitleDiscoveryError.noAvailableServerSessions
        }
        guard responses.contains(where: \.succeeded) else {
            if responses.contains(where: { $0.failure == .authenticationRequired }) {
                throw MultiServerTitleDiscoveryError.serverAuthenticationRequired
            }
            throw MultiServerTitleDiscoveryError.allServersUnavailable
        }
    }

    private static func interleavedResults(
        from responses: [MultiServerTitleDiscoveryServerResult],
        limit: Int
    ) -> [ServerMediaResult] {
        let sortedResponses = responses
            .filter(\.succeeded)
            .sorted { $0.serverIndex < $1.serverIndex }
        var results: [ServerMediaResult] = []
        var itemIndex = 0

        while results.count < limit {
            var appendedItem = false
            for response in sortedResponses where itemIndex < response.items.count {
                results.append(response.items[itemIndex])
                appendedItem = true
                if results.count == limit {
                    break
                }
            }
            guard appendedItem else {
                break
            }
            itemIndex += 1
        }

        return results
    }
}
