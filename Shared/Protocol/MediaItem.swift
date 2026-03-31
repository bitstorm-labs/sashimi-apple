import Foundation

enum MediaItemType: String, Codable, Hashable {
    case movie, series, season, episode, video, collection, folder
}

struct MediaItem: Identifiable, Hashable {
    let id: String              // Composite: "{serverId}:{rawId}"
    let serverId: String
    let rawId: String           // Server-native ID (Jellyfin GUID or Plex ratingKey)
    let title: String
    let type: MediaItemType
    let overview: String?
    let durationSeconds: Double?
    let playbackPositionSeconds: Double?
    let playedPercentage: Double?
    let isPlayed: Bool
    let isFavorite: Bool
    let communityRating: Double?
    let criticRating: Int?
    let officialRating: String?
    let genres: [String]
    let year: Int?
    let seriesId: String?
    let seasonId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let seriesName: String?
    let parentId: String?
    let unplayedCount: Int?
    let hasSubtitles: Bool
    let primaryImageAspectRatio: Double?
    let imageItemId: String?
    let backdropItemId: String?

    // Additional display fields needed by views
    let premiereDate: String?
    let lastPlayedDate: String?
    let parentBackdropImageTags: [String]?
    let backdropImageTags: [String]?
    let path: String?

    // Computed helpers
    var progressPercent: Double {
        guard let playedPercentage else { return 0 }
        return min(max(playedPercentage / 100.0, 0), 1)
    }

    var durationTicks: Int64? {
        durationSeconds.map { Int64($0 * 10_000_000) }
    }

    var positionTicks: Int64? {
        playbackPositionSeconds.map { Int64($0 * 10_000_000) }
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
