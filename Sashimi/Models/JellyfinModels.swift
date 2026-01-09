import Foundation

// swiftlint:disable discouraged_optional_boolean
// Jellyfin API models use optional booleans - this matches the server response structure

struct ServerConfiguration: Codable {
    var serverURL: URL
    var accessToken: String?
    var userId: String?
    var serverName: String?
}

struct AuthenticationResult: Codable {
    let user: UserDto
    let accessToken: String
    let serverId: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

struct UserDto: Codable, Identifiable {
    let id: String
    let name: String
    let serverID: String?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverID = "ServerId"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct BaseItemDto: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: ItemType?
    let seriesName: String?
    let seriesId: String?
    let seasonId: String?
    let parentId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let overview: String?
    let runTimeTicks: Int64?
    let userData: UserItemDataDto?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropImageTags: [String]?
    let primaryImageAspectRatio: Double?
    let mediaType: String?
    let productionYear: Int?
    let communityRating: Double?
    let officialRating: String?
    let genres: [String]?
    let taglines: [String]?
    let people: [PersonInfo]?
    let criticRating: Int?
    let premiereDate: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case parentId = "ParentId"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case overview = "Overview"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case mediaType = "MediaType"
        case productionYear = "ProductionYear"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case genres = "Genres"
        case taglines = "Taglines"
        case people = "People"
        case criticRating = "CriticRating"
        case premiereDate = "PremiereDate"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: BaseItemDto, rhs: BaseItemDto) -> Bool {
        lhs.id == rhs.id
    }

    var displayTitle: String {
        if type == .episode, let seriesName = seriesName {
            let seasonEp = [parentIndexNumber, indexNumber]
                .compactMap { $0 }
                .enumerated()
                .map { $0.offset == 0 ? "S\($0.element)" : "E\($0.element)" }
                .joined()
            return "\(seriesName) \(seasonEp)"
        }
        return name
    }

    var progressPercent: Double {
        guard let playbackTicks = userData?.playbackPositionTicks,
              let totalTicks = runTimeTicks,
              totalTicks > 0 else { return 0 }
        return Double(playbackTicks) / Double(totalTicks)
    }
}

enum ItemType: String, Codable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case video = "Video"
    case boxSet = "BoxSet"
    case folder = "Folder"
    case collectionFolder = "CollectionFolder"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ItemType(rawValue: rawValue) ?? .unknown
    }
}

struct UserItemDataDto: Codable {
    let playbackPositionTicks: Int64?
    let playCount: Int?
    let isFavorite: Bool?
    let played: Bool?
    let lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case lastPlayedDate = "LastPlayedDate"
    }
}

struct ItemsResponse: Codable {
    let items: [BaseItemDto]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct PlaybackInfoResponse: Codable {
    let mediaSources: [MediaSourceInfo]?
    let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

struct MediaSourceInfo: Codable {
    let id: String
    let path: String?
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingUrl: String?
    let directStreamUrl: String?
    let mediaStreams: [MediaStream]?

    var videoCodec: String? {
        mediaStreams?.first(where: { $0.type == "Video" })?.codec
    }

    var videoResolution: String? {
        guard let stream = mediaStreams?.first(where: { $0.type == "Video" }),
              let height = stream.height else { return nil }
        if height >= 2160 { return "4K" }
        if height >= 1080 { return "1080p" }
        if height >= 720 { return "720p" }
        return "\(height)p"
    }

    var audioCodec: String? {
        mediaStreams?.first(where: { $0.type == "Audio" })?.codec
    }

    var audioChannels: Int? {
        mediaStreams?.first(where: { $0.type == "Audio" })?.channels
    }

    var subtitleStreams: [MediaStream] {
        mediaStreams?.filter { $0.type == "Subtitle" } ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case path = "Path"
        case container = "Container"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingUrl = "TranscodingUrl"
        case directStreamUrl = "DirectStreamUrl"
        case mediaStreams = "MediaStreams"
    }
}

struct MediaStream: Codable {
    let type: String?
    let codec: String?
    let language: String?
    let displayTitle: String?
    let title: String?
    let height: Int?
    let width: Int?
    let channels: Int?
    let index: Int?
    let isDefault: Bool?
    let isExternal: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case title = "Title"
        case height = "Height"
        case width = "Width"
        case channels = "Channels"
        case index = "Index"
        case isDefault = "IsDefault"
        case isExternal = "IsExternal"
    }
}

struct PersonInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let type: String?
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct JellyfinLibrary: Codable, Identifiable {
    let id: String
    let name: String
    let collectionType: String?
    let imageTags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
    }
}

struct LibraryViewsResponse: Codable {
    let items: [JellyfinLibrary]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

// MARK: - Media Segments (for skip intro/credits via intro-skipper plugin)

struct MediaSegmentDto: Identifiable {
    let id: String
    let type: MediaSegmentType
    let startSeconds: Double
    let endSeconds: Double
}

enum MediaSegmentType: String {
    case intro = "Introduction"
    case outro = "Credits"
    case preview = "Preview"
    case recap = "Recap"
    case unknown

    var displayName: String {
        switch self {
        case .intro: return "Intro"
        case .outro: return "Credits"
        case .preview: return "Preview"
        case .recap: return "Recap"
        case .unknown: return "Segment"
        }
    }
}

// Intro-skipper plugin response format: {"Introduction": {"Start": 0, "End": 90}, "Credits": {...}}
struct IntroSkipperSegment: Codable {
    let start: Double
    let end: Double

    enum CodingKeys: String, CodingKey {
        case start = "Start"
        case end = "End"
    }
}
