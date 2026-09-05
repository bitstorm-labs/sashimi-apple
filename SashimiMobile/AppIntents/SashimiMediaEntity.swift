import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The server-aware media record shared by Sashimi App Intents.
///
/// This is intentionally an iOS-side projection of the shared Jellyfin model:
/// App Intents can resolve it without exposing the networking model itself to
/// Siri or Shortcuts.
struct SashimiMediaEntity: AppEntity, Codable, Transferable, Hashable, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Sashimi media"
    }

    static var defaultQuery = SashimiMediaEntityQuery()

    static var placeholder: SashimiMediaEntity {
        SashimiMediaEntity(
            id: "0:placeholder",
            title: "",
            serverID: "",
            serverName: "",
            itemID: "",
            mediaType: nil,
            year: nil
        )
    }

    init(
        id: String,
        title: String,
        serverID: String,
        serverName: String,
        itemID: String,
        mediaType: String?,
        year: Int?
    ) {
        self.id = id
        self._title = EntityProperty<String>(title: "Title")
        self.serverID = serverID
        self._serverName = EntityProperty<String>(title: "Server")
        self.itemID = itemID
        self.mediaType = mediaType
        self.year = year
        self.title = title
        self.serverName = serverName
    }

    let id: String
    @Property(title: "Title")
    var title: String
    let serverID: String
    @Property(title: "Server")
    var serverName: String
    let itemID: String
    let mediaType: String?
    let year: Int?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }

    init(item: BaseItemDto, serverID: String, serverName: String) {
        let identifier = SashimiMediaEntityIdentifier(serverID: serverID, itemID: item.id)
        self.id = identifier.rawValue
        self._title = EntityProperty<String>(title: "Title")
        self.serverID = serverID
        self._serverName = EntityProperty<String>(title: "Server")
        self.itemID = item.id
        self.mediaType = item.type?.rawValue
        self.year = item.displayYear
        self.title = item.name
        self.serverName = serverName
    }

    init(result: ServerMediaResult) {
        self.init(item: result.item, serverID: result.serverID, serverName: result.serverName)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case serverID
        case serverName
        case itemID
        case mediaType
        case year
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            serverID: try values.decode(String.self, forKey: .serverID),
            serverName: try values.decode(String.self, forKey: .serverName),
            itemID: try values.decode(String.self, forKey: .itemID),
            mediaType: try values.decodeIfPresent(String.self, forKey: .mediaType),
            year: try values.decodeIfPresent(Int.self, forKey: .year)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(serverID, forKey: .serverID)
        try values.encode(serverName, forKey: .serverName)
        try values.encode(itemID, forKey: .itemID)
        try values.encodeIfPresent(mediaType, forKey: .mediaType)
        try values.encodeIfPresent(year, forKey: .year)
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

#if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let serverID = self.serverID
            let itemID = self.itemID
            return DisplayRepresentation(
                title: "\(title)",
                subtitle: subtitle,
                image: {
                    await Self.posterImage(serverID: serverID, itemID: itemID)
                }
            )
        }
#endif

        return DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle,
            image: DisplayRepresentation.Image(systemName: "play.rectangle")
        )
    }

    static func == (lhs: SashimiMediaEntity, rhs: SashimiMediaEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    private static func posterImage(
        serverID: String,
        itemID: String
    ) async -> DisplayRepresentation.Image? {
        let fallback = DisplayRepresentation.Image(systemName: "play.rectangle")
        await SessionManager.shared.restoreSessionForIntent()
        let serverURL = await MainActor.run {
            SessionManager.shared.servers.first(where: { $0.id == serverID })?.url
        }
        guard !serverID.isEmpty,
              !itemID.isEmpty,
              let serverURL,
              let imageURL = posterURL(itemID: itemID, serverURL: serverURL) else {
            return fallback
        }

        do {
            // Use the app's authenticated image pipeline. Passing the token in
            // a URL would expose private Jellyfin credentials to Spotlight or
            // Siri, and URLSession.shared would bypass self-signed certificate
            // allowances already honored by normal Sashimi artwork.
            let request = SashimiImagePipeline.request(url: imageURL, serverID: serverID)
            let (data, _) = try await SashimiImagePipeline.shared.data(for: request)
            guard !data.isEmpty else { return fallback }
            return DisplayRepresentation.Image(data: data, displayStyle: .default)
        } catch is CancellationError {
            return nil
        } catch {
            return fallback
        }
    }

    private static func posterURL(itemID: String, serverURL: URL) -> URL? {
        let imageURL = serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemID)
            .appendingPathComponent("Images")
            .appendingPathComponent("Primary")
        guard var components = URLComponents(
            url: imageURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "400"),
            URLQueryItem(name: "quality", value: "90")
        ]
        return components.url
    }
#endif
}

@available(iOS 18.0, *)
extension SashimiMediaEntity: IndexedEntity {}

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
    private let entityResolver: @Sendable (SashimiMediaEntityIdentifier) async throws -> SashimiMediaEntity?

    init() {
        entityResolver = { identifier in
            try await Self.resolveEntity(for: identifier)
        }
    }

    init(
        entityResolver: @escaping @Sendable (SashimiMediaEntityIdentifier) async throws -> SashimiMediaEntity?
    ) {
        self.entityResolver = entityResolver
    }

    func entities(for identifiers: [SashimiMediaEntity.ID]) async throws -> [SashimiMediaEntity] {
        await SessionManager.shared.restoreSessionForIntent()

        let parsedIdentifiers = try identifiers.map { rawIdentifier in
            guard let identifier = SashimiMediaEntityIdentifier(rawValue: rawIdentifier) else {
                throw SashimiMediaEntityQueryError.invalidIdentifier
            }
            return identifier
        }

        var entities: [SashimiMediaEntity] = []
        for identifier in parsedIdentifiers {
            try Task.checkCancellation()
            do {
                if let entity = try await entityResolver(identifier) {
                    entities.append(entity)
                }
            } catch SashimiMediaEntityQueryError.itemUnavailable {
                // A deleted or otherwise unavailable item should not discard
                // entities that resolve successfully later in the batch.
            }
            try Task.checkCancellation()
        }
        return entities
    }

    func suggestedEntities() async throws -> [SashimiMediaEntity] {
        await SessionManager.shared.restoreSessionForIntent()
        guard #available(iOS 18.0, *) else { return [] }
        return Array(
            (await SashimiMediaSpotlightIndexer.shared.fetchSuggestedEntities())
                .prefix(24)
        )
    }

    func entities(matching string: String) async throws -> [SashimiMediaEntity] {
        let query = SashimiMediaSearchQuery.normalizedTerm(string)
        guard !query.isEmpty else { return [] }

        await SessionManager.shared.restoreSessionForIntent()

        // A season is not returned by the normal title search endpoint. Resolve
        // an explicit season phrase through the playback resolver so OpenIntent
        // can still turn “Season 2 of Ghosts” into the season's server-scoped
        // entity before the detail route is presented.
        let playbackRequest = SashimiPlaybackRequest(rawTerm: string)
        if playbackRequest.hasExplicitPlaybackDirective,
           case .season = playbackRequest.selection {
            let resolution = await SashimiMediaPlaybackResolver.resolve(request: playbackRequest)
            guard !resolution.matches.isEmpty else {
                if resolution.queriedServerCount == 0
                    || resolution.failedServerCount == resolution.queriedServerCount {
                    throw SashimiMediaEntityQueryError.unavailableServer
                }
                return []
            }
            return resolution.matches
        }

        let search = await MultiServerSearchService.searchWithStatus(query: query, limit: 50)
        if !search.results.isEmpty {
            return search.results.map(SashimiMediaEntity.init(result:))
        }

        // Siri's system search can reduce “season 2 of Ghosts” to “Ghosts 2”
        // before the AppEntity query receives it. Only reinterpret that shape
        // after a normal title search is empty, so a real title such as
        // “Apollo 13” keeps its ordinary search behavior.
        let shorthandRequest = SashimiPlaybackRequest(
            rawTerm: query,
            allowSeasonShorthand: true
        )
        if shorthandRequest.isSeasonShorthand {
            let resolution = await SashimiMediaPlaybackResolver.resolve(request: shorthandRequest)
            if !resolution.matches.isEmpty {
                return resolution.matches
            }
        }

        guard !search.hasServerFailures else {
            throw SashimiMediaEntityQueryError.unavailableServer
        }
        return []
    }

    private static func resolveEntity(for identifier: SashimiMediaEntityIdentifier) async throws -> SashimiMediaEntity? {
        let connection: SashimiMediaServerConnection
        switch await serverConnection(for: identifier.serverID) {
        case .unavailable:
            return nil
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
            return SashimiMediaEntity(
                item: item,
                serverID: connection.id,
                serverName: connection.name
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SashimiMediaEntityQueryError.itemUnavailable
        }
    }

    private static func serverConnection(for serverID: String) async -> SashimiMediaServerConnectionResult {
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

/// Removes conversational wrappers that Siri may include in a
/// `StringSearchCriteria`. Apple documents that the criteria contains the
/// full term spoken by the person, so the app must not assume that only the
/// title is passed to a `ShowInAppSearchResultsIntent`.
enum SashimiMediaSearchQuery {
    static func isExplicitOpenRequest(_ rawValue: String) -> Bool {
        let value = collapseWhitespace(rawValue)
        guard matches(
            value,
            pattern: #"^\s*(?:please\s+)?(?:open|go\s+to|show(?:\s+me)?)\b"#
        ) else {
            return false
        }

        // These phrases belong to the latest-additions discovery action, not
        // to the single-title open route.
        return !isLatestAdditionsRequest(value)
    }

    static func isLatestAdditionsRequest(_ rawValue: String) -> Bool {
        var value = normalizedTerm(rawValue).lowercased()
        if value.hasPrefix("the ") {
            value.removeFirst(4)
        }

        switch value {
        case "latest additions", "new additions", "recent additions", "what's new", "what is new":
            return true
        default:
            return false
        }
    }

    static func normalizedTerm(_ rawValue: String) -> String {
        var value = collapseWhitespace(rawValue)
        guard !value.isEmpty else { return value }

        value = replacing(
            value,
            pattern: #"\s+(?:in|on|from|using)\s+(?:the\s+)?sashimi(?:\s+app)?\s*$"#
        )
        value = replacing(
            value,
            pattern: #"\s+(?:the\s+)?sashimi(?:\s+app)?\s*$"#
        )
        value = replacing(
            value,
            pattern: #"^\s*(?:search|find|show|look\s+up)\s+(?:(?:in|on)\s+)?(?:the\s+)?sashimi(?:\s+app)?(?:\s+for)?\s*"#
        )
        value = replacing(
            value,
            pattern: #"^\s*(?:please\s+)?(?:play|resume|watch|start|open|go\s+to)\s+"#
        )
        value = replacing(
            value,
            pattern: #"^\s*(?:search|find|show(?:\s+me)?|look\s+up)(?:\s+for)?\s+"#
        )
        value = replacing(
            value,
            pattern: #"^\s*(?:is|are|can\s+i\s+(?:watch|see|find)|where\s+can\s+i\s+(?:watch|see)|what\s+can\s+i\s+watch|do\s+you\s+have)\s+"#
        )

        return value.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?:;\n\t"))
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, options: [], range: range) != nil
    }

    private static func replacing(_ value: String, pattern: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: ""
        )
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
extension SashimiMediaEntityQuery: IndexedEntityQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]

    func reindexEntities(
        for identifiers: [SashimiMediaEntity.ID],
        indexDescription _: CSSearchableIndexDescription
    ) async throws {
        let entities = try await entities(for: identifiers)
        guard !entities.isEmpty else { return }

        try await CSSearchableIndex(name: "com.mondominator.sashimi.media")
            .indexAppEntities(entities, priority: 1)
    }

    func reindexAllEntities(indexDescription _: CSSearchableIndexDescription) async throws {
        await SashimiMediaSpotlightIndexer.shared.reindexNow()
    }
}

/// Server-backed entities are not practical to index exhaustively. This
/// iOS 27 query gives Siri and Apple Intelligence a structured live lookup for
/// title references while the existing EntityStringQuery continues to serve
/// Shortcuts and older system resolution paths.
@available(iOS 27.0, *)
extension SashimiMediaEntityQuery: IntentValueQuery {
    typealias Input = StringSearchCriteria

    func values(for input: StringSearchCriteria) async throws -> [SashimiMediaEntity] {
        let query = SashimiMediaSearchQuery.normalizedTerm(input.term)
        guard !query.isEmpty else { return [] }

        await SessionManager.shared.restoreSessionForIntent()

        let playbackRequest = SashimiPlaybackRequest(rawTerm: input.term)
        if playbackRequest.hasExplicitPlaybackDirective,
           case .season = playbackRequest.selection {
            let resolution = await SashimiMediaPlaybackResolver.resolve(request: playbackRequest)
            guard !resolution.matches.isEmpty else {
                if resolution.queriedServerCount == 0
                    || resolution.failedServerCount == resolution.queriedServerCount {
                    throw SashimiMediaEntityQueryError.unavailableServer
                }
                return []
            }
            return Array(resolution.matches.prefix(6))
        }

        let search = await MultiServerSearchService.searchWithStatus(query: query, limit: 50)
        guard !search.results.isEmpty || !search.hasServerFailures else {
            throw SashimiMediaEntityQueryError.unavailableServer
        }

        let preferredServerID = await MainActor.run { SessionManager.shared.activeServerId }
        return ServerMediaResultGrouping.groups(
            from: search.results,
            preferredServerID: preferredServerID
        )
        .prefix(6)
        .map { SashimiMediaEntity(result: $0.primary) }
    }
}
#endif

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
