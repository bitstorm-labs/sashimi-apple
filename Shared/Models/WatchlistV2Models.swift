import Foundation

// Watchlist v2 (Sashimi Lists plugin 0.3.0): search, details of a title the
// server doesn't have, and the server's Requests address. Contract:
// plans/sashimi/2026-11-10-watchlist-v2-api.md. A 404 on any of these routes
// means an older plugin: the feature is hidden, never an error.

/// One result of `GET /SashimiLists/Watchlist/Search`.
struct WatchlistSearchHit: Decodable, Equatable, Identifiable, Sendable {
    let kind: WatchlistKind
    let title: String
    let year: Int?
    let ids: WatchlistIds
    let posterURL: URL?
    let overview: String?
    /// Set for "On your server" hits only.
    let itemId: String?
    let onWatchlist: Bool
    let watchlistEntryId: String?

    /// Kind plus the first id; TMDB movie and show numbers are separate spaces.
    var id: String {
        "\(kind.rawValue)-" + (ids.tmdb.map { "tmdb\($0)" } ?? ids.tvdb.map { "tvdb\($0)" } ?? ids.imdb.map { "imdb\($0)" } ?? title)
    }

    private enum CodingKeys: String, CodingKey {
        case title, year, overview, itemId, onWatchlist, watchlistEntryId, tmdbId, tvdbId, imdbId
        case kind = "type"
        case posterURL = "posterUrl"
    }

    init(kind: WatchlistKind, title: String, year: Int? = nil, ids: WatchlistIds, posterURL: URL? = nil,
         overview: String? = nil, itemId: String? = nil, onWatchlist: Bool = false, watchlistEntryId: String? = nil) {
        self.kind = kind
        self.title = title
        self.year = year
        self.ids = ids
        self.posterURL = posterURL
        self.overview = overview
        self.itemId = itemId
        self.onWatchlist = onWatchlist
        self.watchlistEntryId = watchlistEntryId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WatchlistKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        ids = WatchlistIds(tmdb: try c.decodeIfPresent(String.self, forKey: .tmdbId),
                           tvdb: try c.decodeIfPresent(String.self, forKey: .tvdbId),
                           imdb: try c.decodeIfPresent(String.self, forKey: .imdbId))
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL).flatMap(URL.init(string:))
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        onWatchlist = try c.decodeIfPresent(Bool.self, forKey: .onWatchlist) ?? false
        watchlistEntryId = try c.decodeIfPresent(String.self, forKey: .watchlistEntryId)
    }

    /// What ＋ posts: the hit's own fields.
    var newEntry: NewWatchlistEntry {
        NewWatchlistEntry(type: kind, title: title, year: year, posterUrl: posterURL?.absoluteString,
                          tmdbId: ids.tmdb, tvdbId: ids.tvdb, imdbId: ids.imdb)
    }

    /// The title page's starting point for a "Not on server" hit.
    var titleSeed: WatchlistTitleSeed {
        WatchlistTitleSeed(kind: kind, title: title, year: year, posterURL: posterURL, ids: ids,
                           watchlistEntryId: onWatchlist ? watchlistEntryId : nil)
    }
}

struct WatchlistSearchResponse: Decodable, Equatable, Sendable {
    /// The trimmed query the server used: a response for older text is dropped.
    let query: String
    let onServer: [WatchlistSearchHit]
    let notOnServer: [WatchlistSearchHit]

    init(query: String, onServer: [WatchlistSearchHit], notOnServer: [WatchlistSearchHit]) {
        self.query = query
        self.onServer = onServer
        self.notOnServer = notOnServer
    }

    private enum CodingKeys: String, CodingKey { case query, onServer, notOnServer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        onServer = try c.decodeIfPresent([WatchlistSearchHit].self, forKey: .onServer) ?? []
        notOnServer = try c.decodeIfPresent([WatchlistSearchHit].self, forKey: .notOnServer) ?? []
    }
}

/// `GET /SashimiLists/Watchlist/Details`: a title the server doesn't have,
/// from its metadata providers. Everything but `kind`, `title` and
/// `onWatchlist` may be missing.
struct WatchlistTitleDetails: Decodable, Equatable, Sendable {
    let kind: WatchlistKind
    let title: String
    let year: Int?
    let overview: String?
    let posterURL: URL?
    let backdropURL: URL?
    let runtimeMinutes: Int?
    let seasonCount: Int?
    let officialRating: String?
    let genres: [String]
    let communityRating: Double?
    /// "TMDB": "Details from TMDB".
    let source: String?
    let ids: WatchlistIds
    /// The title IS on the server (and this person can see it): open its library page.
    let itemId: String?
    let onWatchlist: Bool
    let watchlistEntryId: String?

    private enum CodingKeys: String, CodingKey {
        case title, year, overview, runtimeMinutes, seasonCount, officialRating, genres, communityRating, source
        case tmdbId, tvdbId, imdbId, itemId, onWatchlist, watchlistEntryId
        case kind = "type"
        case posterURL = "posterUrl"
        case backdropURL = "backdropUrl"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(WatchlistKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL).flatMap(URL.init(string:))
        backdropURL = try c.decodeIfPresent(String.self, forKey: .backdropURL).flatMap(URL.init(string:))
        runtimeMinutes = try c.decodeIfPresent(Int.self, forKey: .runtimeMinutes)
        seasonCount = try c.decodeIfPresent(Int.self, forKey: .seasonCount)
        officialRating = try c.decodeIfPresent(String.self, forKey: .officialRating)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        communityRating = try c.decodeIfPresent(Double.self, forKey: .communityRating)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        ids = WatchlistIds(tmdb: try c.decodeIfPresent(String.self, forKey: .tmdbId),
                           tvdb: try c.decodeIfPresent(String.self, forKey: .tvdbId),
                           imdb: try c.decodeIfPresent(String.self, forKey: .imdbId))
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        onWatchlist = try c.decodeIfPresent(Bool.self, forKey: .onWatchlist) ?? false
        watchlistEntryId = try c.decodeIfPresent(String.self, forKey: .watchlistEntryId)
    }
}

/// `GET /SashimiLists/Config`: server-wide settings the apps follow.
struct SashimiListsConfig: Decodable, Equatable, Sendable {
    /// The Requests (Seerr) address the server sets; nil when it sets none.
    let requestsURL: URL?

    private enum CodingKeys: String, CodingKey { case requestsURL = "requestsUrl" }

    init(requestsURL: URL?) {
        self.requestsURL = requestsURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .requestsURL)
        // Only an http(s) address counts; anything else is "not set".
        requestsURL = raw.flatMap(SeerrSession.normalizedServerURL)
    }
}

/// What the title page knows before the server answers: from a search hit or
/// a Watchlist entry.
struct WatchlistTitleSeed: Equatable, Identifiable, Sendable {
    let kind: WatchlistKind
    let title: String
    let year: Int?
    let posterURL: URL?
    let ids: WatchlistIds
    /// The Watchlist entry for this title, when it is on the Watchlist.
    let watchlistEntryId: String?

    var id: String { "\(kind.rawValue)-\(ids.tmdb ?? "")-\(ids.tvdb ?? "")-\(ids.imdb ?? "")" }

    init(kind: WatchlistKind, title: String, year: Int?, posterURL: URL?, ids: WatchlistIds, watchlistEntryId: String?) {
        self.kind = kind
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.ids = ids
        self.watchlistEntryId = watchlistEntryId
    }

    init(entry: WatchlistEntry) {
        self.init(kind: entry.kind, title: entry.title, year: entry.year, posterURL: entry.posterURL, ids: entry.ids,
                  watchlistEntryId: entry.id)
    }
}
