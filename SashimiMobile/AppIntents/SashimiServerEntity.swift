import AppIntents
import Foundation

/// A saved server exposed as an optional advanced scope in Shortcuts.
///
/// Server identity is intentionally limited to the persisted server ID and
/// display metadata. Credentials and access tokens never cross the App
/// Intents boundary.
struct SashimiServerEntity: AppEntity, Hashable, Sendable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Sashimi server"
    }

    static var defaultQuery = SashimiServerEntityQuery()

    let id: String
    let name: String
    let host: String

    init(server: ServerConfig) {
        self.id = server.id
        self.name = server.displayName
        self.host = server.url.host ?? server.url.absoluteString
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(host)"
        )
    }

    static func == (lhs: SashimiServerEntity, rhs: SashimiServerEntity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct SashimiServerEntityQuery: EntityStringQuery {
    func entities(for identifiers: [SashimiServerEntity.ID]) async throws -> [SashimiServerEntity] {
        let servers = await savedServers()
        try Task.checkCancellation()

        let entitiesByID = Dictionary(
            uniqueKeysWithValues: servers.map { server in
                (server.id, SashimiServerEntity(server: server))
            }
        )
        return identifiers.compactMap { entitiesByID[$0] }
    }

    func suggestedEntities() async throws -> [SashimiServerEntity] {
        let servers = await savedServers()
        try Task.checkCancellation()
        return servers.map(SashimiServerEntity.init(server:))
    }

    func entities(matching string: String) async throws -> [SashimiServerEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let servers = await savedServers()
        try Task.checkCancellation()
        return servers
            .filter { server in
                server.displayName.localizedCaseInsensitiveContains(query)
                    || (server.url.host?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .map(SashimiServerEntity.init(server:))
    }

    private func savedServers() async -> [ServerConfig] {
        await MainActor.run { SessionManager.shared.servers }
    }
}
