import Foundation

// Seerr (Overseerr/Jellyseerr) API shapes, checked against seerr-api.yml and
// the server entities in seerr-team/seerr (3.5.x). Every field the app does
// not strictly need is optional, so one odd search result can't fail a
// whole page. Secrets the server can return on a user (plexToken,
// jellyfinAuthToken) are deliberately not decoded.

/// Movie or show. Seerr's search also returns people (and the odd
/// collection); those don't decode into this and are dropped.
enum SeerrMediaKind: String, Codable, Hashable, Sendable {
    case movie
    case tv
}

/// `MediaStatus` on the server: whether a title (or one season) is on the
/// media server, on its way, or nowhere.
enum SeerrMediaStatus: Int, Sendable {
    case unknown = 1
    case pending = 2
    case processing = 3
    case partiallyAvailable = 4
    case available = 5
    case blocklisted = 6
    case deleted = 7
}

/// `MediaRequestStatus` on the server.
enum SeerrRequestStatus: Int, Sendable {
    case pending = 1
    case approved = 2
    case declined = 3
    case failed = 4
    case completed = 5
}

struct SeerrUser: Codable, Equatable, Sendable {
    let id: Int
    var displayName: String?
    var username: String?
    var plexUsername: String?
    var email: String?
    /// Seerr's permission bits (`SeerrPermissions`). Nil when the account
    /// was restored offline before it was ever saved.
    var permissions: Int?

    /// What "Signed in as …" shows.
    var name: String {
        for candidate in [displayName, username, plexUsername, email] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
        }
        return "Seerr user"
    }
}

/// `GET /api/v1/settings/public`: needs no sign-in.
struct SeerrPublicSettings: Decodable, Equatable, Sendable {
    var applicationTitle: String?
    var localLogin: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    var partialRequestsEnabled: Bool?  // swiftlint:disable:this discouraged_optional_boolean
}

struct SeerrSeasonStatus: Decodable, Equatable, Sendable {
    let seasonNumber: Int
    let status: Int?
}

struct SeerrSeasonRequest: Decodable, Equatable, Sendable {
    let seasonNumber: Int
    let status: Int?
}

/// One download Seerr sees in Radarr/Sonarr for the title.
struct SeerrDownload: Decodable, Equatable, Sendable {
    let size: Double?
    let sizeLeft: Double?
}

/// `MediaInfo`: the server's record of a title. Absent when nobody has ever
/// requested it and it was never seen on the media server.
struct SeerrMediaInfo: Decodable, Equatable, Sendable {
    var id: Int?
    var tmdbId: Int?
    var mediaType: SeerrMediaKind?
    var status: Int?
    var seasons: [SeerrSeasonStatus]?
    var requests: [SeerrRequest]?
    var downloadStatus: [SeerrDownload]?
    var mediaAddedAt: String?
    var updatedAt: String?

    var mediaStatus: SeerrMediaStatus? { status.flatMap(SeerrMediaStatus.init(rawValue:)) }
}

/// A request's requester (or approver). Seerr fills `displayName` in itself
/// from the username, Plex or Jellyfin name, or email.
struct SeerrRequestUser: Decodable, Equatable, Sendable {
    let id: Int
    var displayName: String?
    var username: String?
    var plexUsername: String?
    /// A full URL (Plex, Gravatar) or a server path ("/avatarproxy/…").
    var avatar: String?

    init(id: Int, displayName: String? = nil, username: String? = nil, plexUsername: String? = nil, avatar: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.plexUsername = plexUsername
        self.avatar = avatar
    }

    var name: String {
        for candidate in [displayName, username, plexUsername] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        }
        return "User \(id)"
    }

    /// The avatar, resolved against the Seerr server for a server path.
    func avatarURL(server: URL) -> URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        if avatar.hasPrefix("http://") || avatar.hasPrefix("https://") { return URL(string: avatar) }
        guard avatar.hasPrefix("/") else { return nil }
        return URL(string: server.absoluteString + avatar)
    }
}

/// `MediaRequest`.
struct SeerrRequest: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let status: Int
    var type: SeerrMediaKind?
    var createdAt: String?
    var updatedAt: String?
    var seasons: [SeerrSeasonRequest]?
    var media: SeerrMediaInfo?
    var requestedBy: SeerrRequestUser?
    var modifiedBy: SeerrRequestUser?

    var requestStatus: SeerrRequestStatus? { SeerrRequestStatus(rawValue: status) }
}

struct SeerrRequestPage: Decodable, Sendable {
    let results: [SeerrRequest]
    var pageInfo: SeerrPageInfo?
}

/// `pageInfo` on `GET /request`: `results` is the total across pages.
struct SeerrPageInfo: Decodable, Equatable, Sendable {
    var pages: Int?
    var pageSize: Int?
    var results: Int?
    var page: Int?
}

/// One search hit. Only movies and shows decode; people and anything else
/// are skipped by `SeerrSearchPage`.
struct SeerrSearchResult: Decodable, Equatable, Identifiable, Sendable {
    let tmdbId: Int
    let kind: SeerrMediaKind
    var title: String
    var date: String?
    var posterPath: String?
    var backdropPath: String?
    var overview: String?
    var mediaInfo: SeerrMediaInfo?

    var id: String { "\(kind.rawValue)-\(tmdbId)" }
    var year: Int? { SeerrDates.year(from: date) }

    init(
        tmdbId: Int,
        kind: SeerrMediaKind,
        title: String,
        date: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        overview: String? = nil,
        mediaInfo: SeerrMediaInfo? = nil
    ) {
        self.tmdbId = tmdbId
        self.kind = kind
        self.title = title
        self.date = date
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.overview = overview
        self.mediaInfo = mediaInfo
    }

    private enum CodingKeys: String, CodingKey {
        case id, tmdbId, mediaType, title, name, releaseDate, firstAirDate, posterPath, backdropPath, overview, mediaInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The watchlist names the TMDB id `tmdbId`; for a local (non-Plex)
        // account its `id` is the watchlist entry's own. Everything else
        // only has `id`.
        tmdbId = try container.decodeIfPresent(Int.self, forKey: .tmdbId) ?? container.decode(Int.self, forKey: .id)
        kind = try container.decode(SeerrMediaKind.self, forKey: .mediaType)
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .releaseDate)
            ?? container.decodeIfPresent(String.self, forKey: .firstAirDate)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        mediaInfo = try container.decodeIfPresent(SeerrMediaInfo.self, forKey: .mediaInfo)
    }
}

struct SeerrSearchPage: Decodable, Sendable {
    let page: Int
    let totalPages: Int
    let results: [SeerrSearchResult]

    private enum CodingKeys: String, CodingKey { case page, totalPages, results }

    /// Skips entries that aren't a movie or show (people, collections)
    /// instead of failing the page.
    private struct Lossy: Decodable {
        let value: SeerrSearchResult?
        init(from decoder: Decoder) throws {
            value = try? SeerrSearchResult(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1
        results = try container.decode([Lossy].self, forKey: .results).compactMap(\.value)
    }
}

// MARK: - Details

struct SeerrGenre: Decodable, Equatable, Sendable {
    let name: String
}

struct SeerrVideo: Decodable, Equatable, Sendable {
    let key: String?
    let site: String?
    let type: String?
}

struct SeerrCastMember: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    var character: String?
    var profilePath: String?
}

struct SeerrCredits: Decodable, Equatable, Sendable {
    var cast: [SeerrCastMember]?
}

/// A show's season as TMDB lists it.
struct SeerrSeason: Decodable, Equatable, Sendable {
    let seasonNumber: Int
    var episodeCount: Int?
    var airDate: String?
    var name: String?
}

struct SeerrRating: Decodable, Equatable, Sendable {
    // swiftlint:disable:next identifier_name
    let iso_3166_1: String?
    let rating: String?
}

struct SeerrRatings: Decodable, Equatable, Sendable {
    var results: [SeerrRating]?
}

struct SeerrReleaseDate: Decodable, Equatable, Sendable {
    let certification: String?
}

struct SeerrCountryRelease: Decodable, Equatable, Sendable {
    // swiftlint:disable:next identifier_name
    let iso_3166_1: String?
    // swiftlint:disable:next identifier_name
    let release_dates: [SeerrReleaseDate]?
}

struct SeerrReleases: Decodable, Equatable, Sendable {
    var results: [SeerrCountryRelease]?
}

/// `GET /api/v1/movie/{id}` or `/tv/{id}`, as one shape: the two differ only
/// in field names (title/name, releaseDate/firstAirDate) and the parts only a
/// show has (seasons, status).
struct SeerrTitleDetails: Decodable, Equatable, Sendable {
    let tmdbId: Int
    var kind: SeerrMediaKind
    var title: String
    var date: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genres: [SeerrGenre]
    var relatedVideos: [SeerrVideo]
    var credits: SeerrCredits?
    var mediaInfo: SeerrMediaInfo?
    /// TMDB's show status ("Returning Series", "Ended", …); nil on a movie.
    var tmdbStatus: String?
    var seasons: [SeerrSeason]
    /// TV: content ratings per country. Movies: certifications per country.
    var contentRating: String?

    var year: Int? { SeerrDates.year(from: date) }

    /// The first YouTube trailer (or teaser), for the Trailer button.
    var trailerKey: String? {
        let youTube = relatedVideos.filter { $0.site == "YouTube" && $0.key != nil }
        return (youTube.first { $0.type == "Trailer" } ?? youTube.first { $0.type == "Teaser" })?.key
    }

    var seriesStatus: SeriesStatus? {
        kind == .tv ? SeriesStatus(tmdbStatus: tmdbStatus) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, name, releaseDate, firstAirDate, overview, posterPath, backdropPath, genres
        case relatedVideos, credits, mediaInfo, status, seasons, contentRatings, releases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tmdbId = try container.decode(Int.self, forKey: .id)
        let movieTitle = try container.decodeIfPresent(String.self, forKey: .title)
        kind = movieTitle == nil ? .tv : .movie
        title = try movieTitle ?? container.decodeIfPresent(String.self, forKey: .name) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .releaseDate)
            ?? container.decodeIfPresent(String.self, forKey: .firstAirDate)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        genres = try container.decodeIfPresent([SeerrGenre].self, forKey: .genres) ?? []
        relatedVideos = try container.decodeIfPresent([SeerrVideo].self, forKey: .relatedVideos) ?? []
        credits = try container.decodeIfPresent(SeerrCredits.self, forKey: .credits)
        mediaInfo = try container.decodeIfPresent(SeerrMediaInfo.self, forKey: .mediaInfo)
        tmdbStatus = try container.decodeIfPresent(String.self, forKey: .status)
        seasons = try container.decodeIfPresent([SeerrSeason].self, forKey: .seasons) ?? []
        let tvRatings = try container.decodeIfPresent(SeerrRatings.self, forKey: .contentRatings)
        let releases = try container.decodeIfPresent(SeerrReleases.self, forKey: .releases)
        contentRating = Self.rating(tv: tvRatings, movie: releases)
    }

    /// The US rating when there is one, else the first non-empty one.
    private static func rating(tv: SeerrRatings?, movie: SeerrReleases?) -> String? {
        if let results = tv?.results {
            let rated = results.filter { !($0.rating ?? "").isEmpty }
            return (rated.first { $0.iso_3166_1 == "US" } ?? rated.first)?.rating
        }
        guard let countries = movie?.results else { return nil }
        func certification(_ country: SeerrCountryRelease) -> String? {
            country.release_dates?.compactMap(\.certification).first { !$0.isEmpty }
        }
        if let us = countries.first(where: { $0.iso_3166_1 == "US" }), let rating = certification(us) {
            return rating
        }
        return countries.lazy.compactMap(certification).first
    }
}

// MARK: - Plex PIN

/// `POST https://plex.tv/api/v2/pins` / `GET …/pins/{id}`. `authToken` is set
/// once the person has entered the code (or signed in on the web page).
struct PlexPin: Decodable, Equatable, Sendable {
    let id: Int
    let code: String
    var authToken: String?
    var expiresAt: String?
}

// MARK: - Helpers

enum SeerrDates {
    /// "2024-11-17" → 2024.
    static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// Seerr's dates: ISO 8601 with or without fractional seconds, or a bare
    /// TMDB "yyyy-MM-dd" air date (read as midnight UTC).
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: string)
    }
}

enum SeerrImages {
    /// TMDB artwork by path ("/abc.jpg"). Seerr hands out TMDB paths; the
    /// images themselves come from TMDB's CDN like on the Seerr website.
    static func poster(_ path: String?, width: Int = 500) -> URL? {
        url(path, size: "w\(width)")
    }

    static func backdrop(_ path: String?) -> URL? {
        url(path, size: "w1280")
    }

    /// TMDB's smallest backdrop size that covers `pixelWidth`: w780, w1280,
    /// or the original (up to 3840 wide) for a big screen.
    static func backdrop(_ path: String?, pixelWidth: Int) -> URL? {
        let size = pixelWidth <= 780 ? "w780" : pixelWidth <= 1280 ? "w1280" : "original"
        return url(path, size: size)
    }

    static func profile(_ path: String?) -> URL? {
        url(path, size: "w185")
    }

    private static func url(_ path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}

extension SeriesStatus {
    /// TMDB's show statuses: "Returning Series", "In Production", "Planned",
    /// "Pilot", "Ended", "Canceled".
    init?(tmdbStatus: String?) {
        switch tmdbStatus?.lowercased() {
        case "returning series", "in production": self = .continuing
        case "ended", "canceled", "cancelled": self = .ended
        case "planned", "pilot": self = .upcoming
        default: return nil
        }
    }
}
