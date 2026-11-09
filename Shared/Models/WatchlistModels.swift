import Foundation

enum WatchlistKind: String, Codable, Sendable {
    case movie = "Movie"
    case series = "Series"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unknown watchlist kind \(raw)"))
        }
        self = kind
    }
}

extension WatchlistKind: CaseIterable {}

struct WatchlistIds: Hashable, Sendable {
    var tmdb: String?
    var tvdb: String?
    var imdb: String?

    init(tmdb: String? = nil, tvdb: String? = nil, imdb: String? = nil) {
        self.tmdb = tmdb
        self.tvdb = tvdb
        self.imdb = imdb
    }

    init(providerIds: [String: String]?) {
        func value(_ key: String) -> String? {
            let found = providerIds?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            return found?.isEmpty == false ? found : nil
        }
        self.init(tmdb: value("Tmdb"), tvdb: value("Tvdb"), imdb: value("Imdb"))
    }

    var isEmpty: Bool { tmdb == nil && tvdb == nil && imdb == nil }

    /// True when any id present on both sides is equal (imdb ignores case).
    func agrees(with other: WatchlistIds) -> Bool {
        if let a = tmdb, let b = other.tmdb, a == b { return true }
        if let a = tvdb, let b = other.tvdb, a == b { return true }
        if let a = imdb, let b = other.imdb, a.caseInsensitiveCompare(b) == .orderedSame { return true }
        return false
    }
}

struct PlexLink: Decodable, Equatable, Sendable {
    let username: String
    let needsReconnect: Bool
}

struct WatchlistEntry: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: WatchlistKind
    let title: String
    let year: Int?
    let posterURL: URL?
    let ids: WatchlistIds
    let addedAt: Date?
    let itemId: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, year, addedAt, itemId
        case kind = "type"
        case posterURL = "posterUrl"
        case tmdbId, tvdbId, imdbId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(WatchlistKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL).flatMap { URL(string: $0) }
        ids = WatchlistIds(
            tmdb: try c.decodeIfPresent(String.self, forKey: .tmdbId),
            tvdb: try c.decodeIfPresent(String.self, forKey: .tvdbId),
            imdb: try c.decodeIfPresent(String.self, forKey: .imdbId))
        // An unreadable date must not cost the whole entry.
        let rawDate = try? c.decodeIfPresent(String.self, forKey: .addedAt)
        addedAt = rawDate.flatMap(WatchlistJSON.date(from:))
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
    }

    init(id: String, kind: WatchlistKind, title: String, year: Int? = nil, posterURL: URL? = nil,
         ids: WatchlistIds, addedAt: Date? = nil, itemId: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.ids = ids
        self.addedAt = addedAt
        self.itemId = itemId
    }
}

struct WatchlistResponse: Decodable, Equatable, Sendable {
    let plex: PlexLink?
    let cardDismissed: Bool
    let entries: [WatchlistEntry]
}

struct WatchlistAddResponse: Decodable, Equatable, Sendable {
    let entry: WatchlistEntry
    let added: Bool
}

struct NewWatchlistEntry: Encodable, Equatable, Sendable {
    let type: WatchlistKind
    let title: String
    let year: Int?
    let posterUrl: String?
    let tmdbId: String?
    let tvdbId: String?
    let imdbId: String?
}

enum WatchlistJSON {
    /// Lower-cases each key's first letter so the camelCase contract and
    /// Jellyfin's PascalCase default output both decode.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys[keys.count - 1]
            let name = key.stringValue
            guard key.intValue == nil, let first = name.first else { return key }
            return AnyKey(stringValue: first.lowercased() + name.dropFirst()) ?? key
        }
        return decoder
    }

    static func encoder() -> JSONEncoder { JSONEncoder() }

    /// ISO-8601 with or without fractional seconds; nil when unreadable.
    static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
