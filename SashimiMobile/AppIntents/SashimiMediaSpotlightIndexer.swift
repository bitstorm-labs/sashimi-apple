import AppIntents
import CoreSpotlight
import Foundation
import os

/// Keeps a bounded set of server-scoped media entities available to Spotlight
/// and Apple Intelligence. The live search intent still searches every saved
/// server; this index supplies title context for discovery and entity
/// resolution when Siri starts from a natural-language request.
@available(iOS 18.0, *)
@MainActor
final class SashimiMediaSpotlightIndexer {
    static let shared = SashimiMediaSpotlightIndexer()

    private static let indexName = "com.mondominator.sashimi.media"
    private static let latestLimit = 100
    private static let resumeLimit = 50
    private static let logger = Logger(
        subsystem: "com.mondominator.sashimi",
        category: "MediaSpotlight"
    )

    private var refreshTask: Task<Void, Never>?

    private init() {}

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshIndex()
        }
    }

    /// Performs an index refresh synchronously for IndexedEntityQuery recovery.
    func reindexNow() async {
        refreshTask?.cancel()
        await refreshIndex()
    }

    /// Returns the bounded set of server-backed entities that are useful when
    /// Siri or Shortcuts first presents a title parameter. This intentionally
    /// mirrors the Spotlight snapshot: recent titles plus Continue Watching.
    func fetchSuggestedEntities() async -> [SashimiMediaEntity] {
        let connections = savedConnections()
        guard !connections.isEmpty else { return [] }

        let entities = await fetchEntities(from: connections)
        var seenIDs = Set<String>()
        return entities.filter { seenIDs.insert($0.id).inserted }
    }

    func clear() {
        refreshTask?.cancel()
        refreshTask = Task {
            let index = CSSearchableIndex(name: Self.indexName)
            try? await index.deleteAppEntities(ofType: SashimiMediaEntity.self)
        }
    }

    private func refreshIndex() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }

        let connections = savedConnections()
        guard !connections.isEmpty else {
            await clearIndexedEntities()
            return
        }

        let entities = await fetchEntities(from: connections)
        guard !Task.isCancelled else { return }

        let index = CSSearchableIndex(name: Self.indexName)
        do {
            // Replacing the bounded snapshot removes titles deleted from a
            // server while keeping stale entries from being offered to Siri.
            try await index.deleteAppEntities(ofType: SashimiMediaEntity.self)
            guard !entities.isEmpty else { return }
            try await index.indexAppEntities(entities, priority: 1)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Could not refresh the media search index: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func clearIndexedEntities() async {
        let index = CSSearchableIndex(name: Self.indexName)
        do {
            try await index.deleteAppEntities(ofType: SashimiMediaEntity.self)
        } catch {
            Self.logger.error("Could not clear the media search index: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func savedConnections() -> [ServerConnection] {
        SessionManager.shared.servers.compactMap { server in
            guard let accessToken = SessionManager.shared.token(
                for: server,
                allowLegacyFallback: true
            ) else {
                return nil
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

    private func fetchEntities(from connections: [ServerConnection]) async -> [SashimiMediaEntity] {
        await withTaskGroup(of: [SashimiMediaEntity].self, returning: [SashimiMediaEntity].self) { group in
            for connection in connections {
                group.addTask {
                    await Self.fetchEntities(from: connection)
                }
            }

            var entities: [SashimiMediaEntity] = []
            var seenIDs = Set<String>()
            for await batch in group {
                for entity in batch where seenIDs.insert(entity.id).inserted {
                    entities.append(entity)
                }
            }
            return entities
        }
    }

    private static func fetchEntities(from connection: ServerConnection) async -> [SashimiMediaEntity] {
        let client = JellyfinClient()
        await client.configure(
            serverURL: connection.url,
            accessToken: connection.accessToken,
            userId: connection.userID
        )

        async let latestItems = client.getLatestMedia(
            limit: latestLimit,
            includeWatched: true,
            groupItems: true
        )
        async let resumeItems = client.getResumeItems(limit: resumeLimit)

        let items = ((try? await latestItems) ?? []) + ((try? await resumeItems) ?? [])
        return items.map {
            SashimiMediaEntity(
                item: $0,
                serverID: connection.id,
                serverName: connection.name
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
