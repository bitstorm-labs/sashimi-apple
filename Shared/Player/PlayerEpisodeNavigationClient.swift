import Foundation

/// The small server surface needed to resolve adjacent episodes. Keeping it
/// separate from the playback client makes the transition path testable while
/// preserving the production Jellyfin client and its server identity.
protocol PlayerEpisodeNavigationClient: Sendable {
    func getPlayerItems(
        parentId: String,
        includeTypes: [ItemType],
        sortBy: String,
        limit: Int
    ) async throws -> ItemsResponse
}

extension JellyfinClient: PlayerEpisodeNavigationClient {
    func getPlayerItems(
        parentId: String,
        includeTypes: [ItemType],
        sortBy: String,
        limit: Int
    ) async throws -> ItemsResponse {
        try await getItems(
            parentId: parentId,
            includeTypes: includeTypes,
            sortBy: sortBy,
            limit: limit
        )
    }
}
