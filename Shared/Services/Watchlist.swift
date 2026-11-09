import Foundation

enum Watchlist {
    static func kind(for type: ItemType?) -> WatchlistKind? {
        switch type {
        case .movie: return .movie
        case .series: return .series
        default: return nil
        }
    }

    /// Movies and shows only, and only with at least one external id.
    static func ids(for item: BaseItemDto) -> WatchlistIds? {
        guard kind(for: item.type) != nil else { return nil }
        let ids = WatchlistIds(providerIds: item.providerIds)
        return ids.isEmpty ? nil : ids
    }

    /// No poster: the plugin fills it from Jellyfin's remote images.
    static func newEntry(for item: BaseItemDto) -> NewWatchlistEntry? {
        guard let kind = kind(for: item.type), let ids = ids(for: item) else { return nil }
        return NewWatchlistEntry(type: kind, title: item.name, year: item.productionYear, posterUrl: nil,
                                 tmdbId: ids.tmdb, tvdbId: ids.tvdb, imdbId: ids.imdb)
    }

    static func newEntry(for target: SeerrTarget, year: Int?) -> NewWatchlistEntry {
        NewWatchlistEntry(
            type: target.kind == .movie ? .movie : .series,
            title: target.title, year: year,
            posterUrl: SeerrImages.poster(target.posterPath)?.absoluteString,
            tmdbId: String(target.tmdbId), tvdbId: nil, imdbId: nil)
    }

    static func contains(_ entries: [WatchlistEntry], ids: WatchlistIds) -> Bool {
        entries.contains { $0.ids.agrees(with: ids) }
    }

    enum MissingTag: Equatable {
        case notOnServer, requested

        var label: String {
            switch self {
            case .notOnServer: return WatchlistText.notOnServer
            case .requested: return WatchlistText.requested
            }
        }
    }

    /// A nil badge (no Seerr session, or the lookup failed) reads as not on server.
    static func missingTag(badge: SeerrBadge?) -> MissingTag {
        switch badge {
        case .pending, .coming: return .requested
        default: return .notOnServer
        }
    }

    static func seerrTarget(for entry: WatchlistEntry) -> SeerrTarget? {
        guard let raw = entry.ids.tmdb, let tmdbId = Int(raw) else { return nil }
        return SeerrTarget(kind: entry.kind == .movie ? .movie : .tv, tmdbId: tmdbId, title: entry.title)
    }
}

enum WatchlistText {
    static let name = "Watchlist"
    static let cardTitle = "Use Plex too?"
    static let cardBody = "Connect it and your Plex watchlist and this one stay the same."
    static let connect = "Connect Plex"
    static let notNow = "Not now"
    static let synced = "Synced with Plex"
    static let disconnect = "Disconnect Plex"
    static let reconnect = "Reconnect Plex"
    static let notOnServer = "Not on server"
    static let requested = "Requested"
    static let signIntoRequests = "Sign into Requests to ask for this"
    static let nowSyncs = "Your Watchlist now syncs with Plex"
    static let couldntReachPlex = "Couldn't reach Plex. Try again."

    static func switchQuestion(newUsername: String?) -> String {
        "Sync your Watchlist with \(newUsername.map { "Plex account \($0)" } ?? "this Plex account") instead?"
    }
}
