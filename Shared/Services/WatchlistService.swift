import Foundation

enum WatchlistError: LocalizedError {
    case notEligible

    var errorDescription: String? {
        "Only movies and shows with a known TMDB, TVDB or IMDb id can go on the Watchlist."
    }
}

/// The Watchlist as the app uses it: what to send, and what a missing plugin means.
struct WatchlistService {
    let client: JellyfinClient

    init(client: JellyfinClient = .shared) {
        self.client = client
    }

    /// Nil on 404: no plugin, or one older than 0.2.0.
    func load() async throws -> WatchlistResponse? {
        do {
            return try await client.getWatchlist()
        } catch JellyfinError.httpError(let code) where code == 404 {
            return nil
        }
    }

    /// The ids to file an item under. A thin item (cards and rows carry no
    /// ProviderIds) is fetched in full first.
    func ids(for item: BaseItemDto) async -> WatchlistIds? {
        guard Watchlist.kind(for: item.type) != nil else { return nil }
        if item.providerIds != nil { return Watchlist.ids(for: item) }
        guard let full = try? await client.getItem(itemId: item.id) else { return nil }
        return Watchlist.ids(for: full)
    }

    func add(_ item: BaseItemDto) async throws -> WatchlistAddResponse {
        guard let ids = await ids(for: item), let entry = Watchlist.newEntry(for: item, ids: ids) else {
            throw WatchlistError.notEligible
        }
        return try await client.addToWatchlist(entry)
    }

    func add(_ target: SeerrTarget, year: Int?) async throws -> WatchlistAddResponse {
        try await client.addToWatchlist(Watchlist.newEntry(for: target, year: year))
    }

    func remove(_ entry: WatchlistEntry) async throws {
        try await client.removeFromWatchlist(entryId: entry.id)
    }

    /// The server's items behind entries that are in the library, by id, in one call.
    func libraryItems(for entries: [WatchlistEntry]) async -> [String: BaseItemDto] {
        let ids = entries.compactMap(\.itemId)
        guard !ids.isEmpty, let items = try? await client.getItemsForCards(itemIds: ids) else { return [:] }
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
