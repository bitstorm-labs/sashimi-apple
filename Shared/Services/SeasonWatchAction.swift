import Foundation

/// The server calls needed to flip a whole season. Jellyfin treats a season id
/// on `/Users/{uid}/PlayedItems/{id}` exactly like an item id: POST marks every
/// episode in the season played, DELETE marks them all unplayed.
protocol PlayedStateMarking: Sendable {
    func markPlayed(itemId: String) async throws
    func markUnplayed(itemId: String) async throws
}

extension JellyfinClient: PlayedStateMarking {}

/// "Mark Season Watched" / "Mark Season Unwatched" on a series detail screen.
enum SeasonWatchAction: Equatable {
    case markWatched
    case markUnwatched

    /// Offer Unwatched only when every episode in the season is already played.
    ///
    /// `loadedEpisodes` must be the episodes of `season` (pass nil when the
    /// list on screen belongs to another season or is still loading). Without
    /// them, fall back to the season's own `Played` flag, which Jellyfin sets
    /// once all of its episodes are played.
    static func resolve(season: BaseItemDto, loadedEpisodes: [BaseItemDto]?) -> SeasonWatchAction {
        if let episodes = loadedEpisodes, !episodes.isEmpty {
            let allPlayed = episodes.allSatisfy { $0.userData?.played == true }
            return allPlayed ? .markUnwatched : .markWatched
        }
        return season.userData?.played == true ? .markUnwatched : .markWatched
    }

    var title: String {
        switch self {
        case .markWatched: return "Mark Season Watched"
        case .markUnwatched: return "Mark Season Unwatched"
        }
    }

    var systemImage: String {
        switch self {
        case .markWatched: return "eye"
        case .markUnwatched: return "eye.slash"
        }
    }

    func confirmationMessage(seasonName: String) -> String {
        switch self {
        case .markWatched: return "Mark every episode of \(seasonName) as watched?"
        case .markUnwatched: return "Mark every episode of \(seasonName) as unwatched?"
        }
    }

    var successMessage: String {
        switch self {
        case .markWatched: return "Season marked as watched"
        case .markUnwatched: return "Season marked as unwatched"
        }
    }

    /// Seasons synthesised from offline downloads ("offline-season-N") are not
    /// server items, and nothing can be marked without a connection.
    static func canApply(to season: BaseItemDto, isConnected: Bool) -> Bool {
        isConnected && !season.id.hasPrefix("offline-season-")
    }

    static let failureMessage = "Failed to update season watched status"

    /// One request for the whole season; safe to repeat (the server call is idempotent).
    func apply(seasonId: String, using client: PlayedStateMarking = JellyfinClient.shared) async throws {
        switch self {
        case .markWatched: try await client.markPlayed(itemId: seasonId)
        case .markUnwatched: try await client.markUnplayed(itemId: seasonId)
        }
    }
}

/// The series page's watched control (#749): the series itself and, under it,
/// the season on screen. The season entry used to exist only as a long-press
/// on the season tab, which nobody found.
enum WatchedScopeEntry: Equatable {
    /// Mark the whole series watched (true) or unwatched (false).
    case series(markWatched: Bool)
    case season(BaseItemDto, SeasonWatchAction)

    var title: String {
        switch self {
        case .series(let markWatched): return markWatched ? "Mark Series Watched" : "Mark Series Unwatched"
        case .season(_, let action): return action.title
        }
    }

    var systemImage: String {
        switch self {
        case .series(let markWatched): return markWatched ? "eye" : "eye.slash"
        case .season(_, let action): return action.systemImage
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.series(left), .series(right)): return left == right
        case let (.season(leftSeason, leftAction), .season(rightSeason, rightAction)):
            return leftSeason.id == rightSeason.id && leftAction == rightAction
        default: return false
        }
    }

    /// `loadedEpisodes` are the episodes shown for `season` (nil while loading).
    static func entries(
        isSeriesWatched: Bool,
        season: BaseItemDto?,
        loadedEpisodes: [BaseItemDto]?,
        isConnected: Bool
    ) -> [WatchedScopeEntry] {
        var entries: [WatchedScopeEntry] = [.series(markWatched: !isSeriesWatched)]
        if let season, SeasonWatchAction.canApply(to: season, isConnected: isConnected) {
            entries.append(.season(season, SeasonWatchAction.resolve(season: season, loadedEpisodes: loadedEpisodes)))
        }
        return entries
    }
}
