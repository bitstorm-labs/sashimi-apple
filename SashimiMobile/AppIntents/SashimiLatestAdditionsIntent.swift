import AppIntents
import Foundation

#if compiler(>=6.4)
/// Fetches the default server's newest items for every Siri surface that can
/// answer a latest-additions request. Keeping the server selection and error
/// handling here prevents the search schema and App Shortcut from drifting
/// into different behaviors.
@available(iOS 27.0, *)
enum SashimiLatestAdditionsResolver {
    struct Resolution: Sendable {
        let serverName: String
        let entities: [SashimiMediaEntity]
    }

    private static let resultLimit = 12

    static func resolve() async throws -> Resolution {
        let connection = try await defaultServerConnection()

        let client = JellyfinClient()
        await client.configure(
            serverURL: connection.url,
            accessToken: connection.accessToken,
            userId: connection.userID
        )

        do {
            let items = try await client.getLatestMedia(
                limit: resultLimit,
                includeWatched: true,
                groupItems: true
            )
            let entities = items.map {
                SashimiMediaEntity(
                    item: $0,
                    serverID: connection.id,
                    serverName: connection.name
                )
            }
            guard !entities.isEmpty else {
                throw SashimiSiriIntentError.noResults
            }
            return Resolution(serverName: connection.name, entities: entities)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SashimiSiriIntentError {
            throw error
        } catch {
            throw SashimiSiriIntentError.unavailableServer
        }
    }

    private static func defaultServerConnection() async throws -> ServerConnection {
        await SessionManager.shared.restoreSessionForIntent()
        return try await MainActor.run {
            guard SessionManager.shared.isAuthenticated else {
                throw SashimiSiriIntentError.authenticationRequired
            }
            guard NetworkMonitor.shared.isConnected,
                  let server = SessionManager.shared.defaultServer,
                  let accessToken = SessionManager.shared.token(
                      for: server,
                      allowLegacyFallback: true
                  ) else {
                throw SashimiSiriIntentError.unavailableServer
            }
            return ServerConnection(
                id: server.id,
                name: server.displayName,
                url: server.url,
                accessToken: accessToken,
                userID: server.userId
            )
        }
    }

    private struct ServerConnection: Sendable {
        let id: String
        let name: String
        let url: URL
        let accessToken: String
        let userID: String
    }
}

/// Returns the newest titles from Sashimi's default server as a rich Siri
/// result. Search and explicit title playback intentionally fan out across
/// saved servers; "latest additions" is a server-local home-style action and
/// therefore follows the user's default-server preference.
@available(iOS 27.0, *)
struct SashimiLatestAdditionsIntent: AppIntent {
    static var title: LocalizedStringResource {
        "Show Latest Additions in Sashimi"
    }

    static var description: IntentDescription {
        IntentDescription(
            "Show the newest movies, shows, and videos added to Sashimi's default server.",
            categoryName: "Media discovery",
            searchKeywords: [
                "Sashimi", "latest", "new", "recent", "recently added", "new additions",
                "movies", "shows", "videos"
            ]
        )
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Show the latest additions in Sashimi")
    }

    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }

    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let supportedModes: IntentModes = [.background]

    // Keep the default-server fetch and result assembly in one path so this
    // action cannot accidentally fall back to another server.
    func perform() async throws -> some ReturnsValue<[SashimiMediaEntity]> & ShowsSnippetIntent & ProvidesDialog {
        let resolution = try await SashimiLatestAdditionsResolver.resolve()
        return .result(
            value: resolution.entities,
            dialog: IntentDialog(
                full: "Here are the latest additions in Sashimi.",
                supporting: "From \(resolution.serverName)."
            ),
            snippetIntent: SashimiLatestAdditionsSnippetIntent(results: resolution.entities)
        )
    }
}
#endif
