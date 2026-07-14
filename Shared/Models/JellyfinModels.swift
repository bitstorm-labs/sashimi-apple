import Foundation

// MARK: - String Extensions

extension String {
    /// Cleans up YouTube channel titles by removing common suffixes like " - Videos"
    var cleanedYouTubeTitle: String {
        if hasSuffix(" - Videos") {
            return String(dropLast(9))
        }
        return self
    }
}

// swiftlint:disable discouraged_optional_boolean
// Jellyfin API models use optional booleans - this matches the server response structure

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

struct MediaUrl: Codable, Hashable {
    let name: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case url = "Url"
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
    let chapters: [ChapterInfo]?
    let path: String?
    let remoteTrailers: [MediaUrl]?

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
        case chapters = "Chapters"
        case path = "Path"
        case remoteTrailers = "RemoteTrailers"
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
    let unplayedItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case lastPlayedDate = "LastPlayedDate"
        case unplayedItemCount = "UnplayedItemCount"
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
        guard let stream = mediaStreams?.first(where: { $0.type == "Video" }) else { return nil }
        let width = stream.width ?? 0
        let height = stream.height ?? 0
        guard width > 0 || height > 0 else { return nil }
        // Classify by width first: wide-aspect releases (3840x1920, 3840x1600
        // scope) have sub-2160 heights and would otherwise mislabel as 1080p.
        if width >= 3200 || height >= 2160 { return "4K" }
        if width >= 1800 || height >= 1080 { return "1080p" }
        if width >= 1200 || height >= 720 { return "720p" }
        if height > 0 { return "\(height)p" }
        return "SD"
    }

    var audioCodec: String? {
        mediaStreams?.first(where: { $0.type == "Audio" })?.codec
    }

    var audioChannels: Int? {
        mediaStreams?.first(where: { $0.type == "Audio" })?.channels
    }

    var audioStreams: [MediaStream] {
        mediaStreams?.filter { $0.type == "Audio" } ?? []
    }

    var subtitleStreams: [MediaStream] {
        mediaStreams?.filter { $0.type == "Subtitle" } ?? []
    }

    /// Returns unique audio languages (e.g., ["English", "Spanish", "Japanese"])
    var audioLanguages: [String] {
        let languages = audioStreams.compactMap { stream -> String? in
            if let displayTitle = stream.displayTitle, !displayTitle.isEmpty {
                return displayTitle
            }
            if let language = stream.language, !language.isEmpty {
                return Locale.current.localizedString(forLanguageCode: language) ?? language.uppercased()
            }
            return nil
        }
        // Remove duplicates while preserving order
        var seen = Set<String>()
        return languages.filter { seen.insert($0).inserted }
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

// MARK: - Session info (live playback truth from the server)

/// Subset of /Sessions used by the player's stream-info chip. The server is
/// the only source that can distinguish a full transcode from a remux with
/// the video stream copied (IsVideoDirect).
struct SessionInfoDto: Codable {
    let deviceId: String?
    let playState: SessionPlayState?
    let transcodingInfo: SessionTranscodingInfo?
    let nowPlayingItemId: NowPlayingItemRef?

    enum CodingKeys: String, CodingKey {
        case deviceId = "DeviceId"
        case playState = "PlayState"
        case transcodingInfo = "TranscodingInfo"
        case nowPlayingItemId = "NowPlayingItem"
    }
}

/// Minimal reference to the session's playing item (id only — avoids
/// re-decoding a full BaseItemDto we don't need).
struct NowPlayingItemRef: Codable {
    let id: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

struct SessionPlayState: Codable {
    /// "DirectPlay" | "DirectStream" | "Transcode"
    let playMethod: String?

    enum CodingKeys: String, CodingKey {
        case playMethod = "PlayMethod"
    }
}

struct SessionTranscodingInfo: Codable {
    let videoCodec: String?
    let audioCodec: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let isVideoDirect: Bool?
    let isAudioDirect: Bool?
    let transcodeReasons: [String]?

    enum CodingKeys: String, CodingKey {
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case bitrate = "Bitrate"
        case width = "Width"
        case height = "Height"
        case isVideoDirect = "IsVideoDirect"
        case isAudioDirect = "IsAudioDirect"
        case transcodeReasons = "TranscodeReasons"
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
    let videoRangeType: String?

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
        case videoRangeType = "VideoRangeType"
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

struct JellyfinLibrary: Codable, Identifiable, Equatable {
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

// MARK: - Chapters

struct ChapterInfo: Codable {
    let startPositionTicks: Int64
    let name: String?
    let imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }

    var startSeconds: Double {
        Double(startPositionTicks) / 10_000_000.0
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
