import AppIntents
import Foundation

/// The server-aware media record shared by Sashimi App Intents.
///
/// This is intentionally an iOS-side projection of the shared Jellyfin model:
/// App Intents can resolve it without exposing the networking model itself to
/// Siri or Shortcuts.
struct SashimiMediaEntity: AppEntity, Hashable, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Sashimi media"
    }

    static var defaultQuery = SashimiMediaEntityQuery()

    let id: String
    let title: String
    let serverID: String
    let serverName: String
    let itemID: String
    let mediaType: String?
    let year: Int?

    init(item: BaseItemDto, serverID: String, serverName: String) {
        let identifier = SashimiMediaEntityIdentifier(serverID: serverID, itemID: item.id)
        self.id = identifier.rawValue
        self.title = item.name
        self.serverID = serverID
        self.serverName = serverName
        self.itemID = item.id
        self.mediaType = item.type?.rawValue
        self.year = item.displayYear
    }

    init(result: ServerMediaResult) {
        self.init(item: result.item, serverID: result.serverID, serverName: result.serverName)
    }

    var sashimiIdentifier: SashimiMediaEntityIdentifier? {
        SashimiMediaEntityIdentifier(rawValue: id)
    }

    var displayRepresentation: DisplayRepresentation {
        var details: [String] = []
        if let mediaType {
            details.append(mediaType)
        }
        if let year {
            details.append(String(year))
        }
        if !serverName.isEmpty {
            details.append(serverName)
        }

        let subtitle: LocalizedStringResource? = details.isEmpty
            ? nil
            : "\(details.joined(separator: " · "))"
        return DisplayRepresentation(title: "\(title)", subtitle: subtitle)
    }

    static func == (lhs: SashimiMediaEntity, rhs: SashimiMediaEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum SashimiMediaEntityQueryError: LocalizedError, Equatable, Sendable {
    case invalidIdentifier
    case unavailableServer
    case authenticationRequired
    case itemUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "That Sashimi title reference is invalid."
        case .unavailableServer:
            return "The Sashimi server for that title is no longer available."
        case .authenticationRequired:
            return "Sign in to Sashimi to use that title."
        case .itemUnavailable:
            return "That Sashimi title is no longer available."
        }
    }
}

struct SashimiMediaEntityQuery: EntityStringQuery {
    func entities(for identifiers: [SashimiMediaEntity.ID]) async throws -> [SashimiMediaEntity] {
        let parsedIdentifiers = try identifiers.map { rawIdentifier in
            guard let identifier = SashimiMediaEntityIdentifier(rawValue: rawIdentifier) else {
                throw SashimiMediaEntityQueryError.invalidIdentifier
            }
            return identifier
        }

        var entities: [SashimiMediaEntity] = []
        for identifier in parsedIdentifiers {
            let connection: SashimiMediaServerConnection
            switch await serverConnection(for: identifier.serverID) {
            case .unavailable:
                throw SashimiMediaEntityQueryError.unavailableServer
            case .authenticationRequired:
                throw SashimiMediaEntityQueryError.authenticationRequired
            case .connected(let value):
                connection = value
            }

            let client = JellyfinClient()
            await client.configure(
                serverURL: connection.url,
                accessToken: connection.accessToken,
                userId: connection.userID
            )

            do {
                let item = try await client.getItem(itemId: identifier.itemID)
                entities.append(
                    SashimiMediaEntity(
                        item: item,
                        serverID: connection.id,
                        serverName: connection.name
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SashimiMediaEntityQueryError.itemUnavailable
            }
        }
        return entities
    }

    func suggestedEntities() async throws -> [SashimiMediaEntity] {
        // Discovery suggestions are supplied by the latest-titles intent in
        // the next issue. Keeping this empty avoids inventing a server scope
        // before that contract is defined.
        []
    }

    func entities(matching string: String) async throws -> [SashimiMediaEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let results = await MultiServerSearchService.search(query: query, limit: 50)
        return results.map(SashimiMediaEntity.init(result:))
    }

    private func serverConnection(for serverID: String) async -> SashimiMediaServerConnectionResult {
        await MainActor.run {
            guard let server = SessionManager.shared.servers.first(where: { $0.id == serverID }) else {
                return .unavailable
            }
            guard let accessToken = SessionManager.shared.token(for: server, allowLegacyFallback: true) else {
                return .authenticationRequired
            }
            return .connected(
                SashimiMediaServerConnection(
                    id: server.id,
                    name: server.displayName,
                    url: server.url,
                    accessToken: accessToken,
                    userID: server.userId
                )
            )
        }
    }
}

private enum SashimiMediaServerConnectionResult: Sendable {
    case unavailable
    case authenticationRequired
    case connected(SashimiMediaServerConnection)
}

private struct SashimiMediaServerConnection: Sendable {
    let id: String
    let name: String
    let url: URL
    let accessToken: String
    let userID: String
}
