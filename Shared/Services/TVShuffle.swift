import Foundation

/// The server calls a library Shuffle needs, so the choice can be tested
/// without a server. `JellyfinClient` is the real source.
protocol TVShuffleSource: Sendable {
    func randomItem(parentId: String, itemTypes: [ItemType]) async throws -> BaseItemDto?
    func nextUpEpisode(seriesId: String) async throws -> BaseItemDto?
    func firstRegularEpisode(seriesId: String, unplayedOnly: Bool) async throws -> BaseItemDto?
}

extension JellyfinClient: TVShuffleSource {
    func randomItem(parentId: String, itemTypes: [ItemType]) async throws -> BaseItemDto? {
        try await getRandomItem(parentId: parentId, itemTypes: itemTypes)
    }

    func nextUpEpisode(seriesId: String) async throws -> BaseItemDto? {
        try await getNextUp(seriesId: seriesId, limit: 1).first
    }
}

/// Picks what a library's Shuffle button plays.
enum TVShuffle {
    /// `itemTypes` is what the library shuffles: `[.episode]` for a TV
    /// library, which is the only case `mode` applies to. Movies and mixed
    /// libraries always pick at random. A series' own Shuffle doesn't come
    /// through here: inside one show "random show" means nothing.
    static func pick(
        libraryId: String,
        itemTypes: [ItemType],
        mode: TVShuffleMode,
        source: TVShuffleSource
    ) async throws -> BaseItemDto? {
        guard itemTypes == [.episode], mode == .randomShowNextEpisode else {
            return try await source.randomItem(parentId: libraryId, itemTypes: itemTypes)
        }
        guard let series = try await source.randomItem(parentId: libraryId, itemTypes: [.series]) else {
            return nil
        }
        return try await nextEpisode(seriesId: series.id, source: source)
    }

    /// The episode the series' Play button starts: the server's Next Up,
    /// else the first unwatched regular episode, else (all watched) the first
    /// regular episode. Specials never win while a regular one is unwatched.
    static func nextEpisode(seriesId: String, source: TVShuffleSource) async throws -> BaseItemDto? {
        let nextUp = try? await source.nextUpEpisode(seriesId: seriesId)
        if let nextUp, !nextUp.isSpecial {
            return nextUp
        }
        if let unwatched = try await source.firstRegularEpisode(seriesId: seriesId, unplayedOnly: true) {
            return unwatched
        }
        // Every regular episode watched: an unwatched special Next Up offers
        // is next, otherwise start the show over.
        if let nextUp {
            return nextUp
        }
        if let first = try await source.firstRegularEpisode(seriesId: seriesId, unplayedOnly: false) {
            return first
        }
        // A show with nothing but specials.
        return try await source.randomItem(parentId: seriesId, itemTypes: [.episode])
    }
}
