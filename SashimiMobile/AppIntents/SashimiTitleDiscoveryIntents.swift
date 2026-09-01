import AppIntents
import Foundation

enum SashimiTitleDiscoveryIntentError: LocalizedError, Equatable, Sendable {
    case emptySearchQuery
    case noSearchResults(query: String)
    case noRecentlyAddedTitles
    case signedOut
    case defaultServerUnavailable
    case serverUnavailable
    case serverAuthenticationRequired

    var errorDescription: String? {
        switch self {
        case .emptySearchQuery:
            return "Tell Sashimi which title to search for."
        case .noSearchResults(let query):
            return "No Sashimi titles matched \"\(query)\"."
        case .noRecentlyAddedTitles:
            return "Sashimi could not find any recently added titles."
        case .signedOut:
            return "Sign in to a Sashimi server before using title discovery."
        case .defaultServerUnavailable:
            return "Set up a default Sashimi server before requesting recently added titles."
        case .serverUnavailable:
            return "Sashimi could not reach the requested server."
        case .serverAuthenticationRequired:
            return "Sign in to the requested Sashimi server before using it here."
        }
    }

    static func from(_ error: MultiServerTitleDiscoveryError) -> Self {
        switch error {
        case .noAvailableServerSessions:
            return .signedOut
        case .allServersUnavailable:
            return .serverUnavailable
        case .serverNotFound:
            return .serverUnavailable
        case .serverAuthenticationRequired:
            return .serverAuthenticationRequired
        case .defaultServerUnavailable:
            return .defaultServerUnavailable
        }
    }
}

struct FindSashimiTitlesIntent: AppIntent {
    static var title: LocalizedStringResource {
        "Find Sashimi Titles"
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresAuthentication
    }

    static var description: IntentDescription {
        IntentDescription(
            "Search signed-in Sashimi servers for movies and shows.",
            categoryName: "Media discovery",
            searchKeywords: ["Sashimi", "search", "movie", "show", "title"],
            resultValueName: "Sashimi titles"
        )
    }

    @Parameter(
        title: "Search",
        description: "The movie or show title to find."
    )
    var query: String

    @Parameter(
        title: "Maximum Results",
        description: "The maximum number of titles to return.",
        default: 10,
        inclusiveRange: (1, 50)
    )
    var limit: Int

    @Parameter(
        title: "Server",
        description: "Optional. Leave empty to search all signed-in servers."
    )
    var server: SashimiServerEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Find Sashimi titles matching \(\.$query)") {
            \.$limit
            \.$server
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[SashimiMediaEntity]> {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw SashimiTitleDiscoveryIntentError.emptySearchQuery
        }

        let results: [ServerMediaResult]
        do {
            results = try await MultiServerTitleDiscoveryService.search(
                query: normalizedQuery,
                limit: limit,
                serverID: server?.id
            )
        } catch let error as MultiServerTitleDiscoveryError {
            throw SashimiTitleDiscoveryIntentError.from(error)
        }

        guard !results.isEmpty else {
            throw SashimiTitleDiscoveryIntentError.noSearchResults(query: normalizedQuery)
        }

        return .result(value: results.map(SashimiMediaEntity.init(result:)))
    }
}

struct RecentlyAddedSashimiTitlesIntent: AppIntent {
    static var title: LocalizedStringResource {
        "Recently Added Sashimi Titles"
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresAuthentication
    }

    static var description: IntentDescription {
        IntentDescription(
            "Get the newest titles added to a Sashimi server.",
            categoryName: "Media discovery",
            searchKeywords: ["Sashimi", "recently added", "latest", "new titles"],
            resultValueName: "Recently added Sashimi titles"
        )
    }

    @Parameter(
        title: "Maximum Results",
        description: "The maximum number of titles to return.",
        default: 10,
        inclusiveRange: (1, 50)
    )
    var limit: Int

    @Parameter(
        title: "Server",
        description: "Optional. Leave empty to use Sashimi's default server."
    )
    var server: SashimiServerEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get recently added Sashimi titles") {
            \.$limit
            \.$server
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[SashimiMediaEntity]> {
        let results: [ServerMediaResult]
        do {
            results = try await MultiServerTitleDiscoveryService.recentlyAdded(
                limit: limit,
                serverID: server?.id
            )
        } catch let error as MultiServerTitleDiscoveryError {
            throw SashimiTitleDiscoveryIntentError.from(error)
        }

        guard !results.isEmpty else {
            throw SashimiTitleDiscoveryIntentError.noRecentlyAddedTitles
        }

        return .result(value: results.map(SashimiMediaEntity.init(result:)))
    }
}
