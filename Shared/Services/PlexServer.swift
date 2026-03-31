import Foundation

// MARK: - PlexServer

/// Wraps the PlexClient actor to conform to the MediaServer protocol.
/// Thread safety is handled by the underlying PlexClient actor.
final class PlexServer: MediaServer, @unchecked Sendable {
    let id: String
    let name: String
    let serverType: ServerType = .plex
    let serverURL: URL

    private let client: PlexClient

    init(account: ServerAccount, client: PlexClient) {
        self.id = account.id
        self.name = account.serverName
        self.serverURL = account.serverURL
        self.client = client
    }

    // MARK: - Libraries

    func getLibraries() async throws -> [MediaLibrary] {
        let libraries = try await client.getLibraries()
        return libraries.map { mapLibrary($0) }
    }

    // MARK: - Items

    func getResumeItems(limit: Int) async throws -> [MediaItem] {
        let items = try await client.getOnDeck()
        return Array(items.prefix(limit).map { mapItem($0) })
    }

    func getNextUp(limit: Int) async throws -> [MediaItem] {
        // Plex's On Deck serves as both resume and next up
        let items = try await client.getOnDeck()
        // Filter to episodes that have no viewOffset (not partially watched, i.e. truly "next up")
        let nextUp = items.filter { $0.viewOffset == nil || $0.viewOffset == 0 }
        return Array(nextUp.prefix(limit).map { mapItem($0) })
    }

    func getLatestMedia(libraryId: String?, limit: Int) async throws -> [MediaItem] {
        let items = try await client.getRecentlyAdded(sectionKey: libraryId, limit: limit)
        return items.map { mapItem($0) }
    }

    func getItem(id: String) async throws -> MediaItem {
        let metadata = try await client.getItem(ratingKey: id)
        return mapItem(metadata)
    }

    func getChildren( // swiftlint:disable:this function_parameter_count
        parentId: String,
        type: MediaItemType?,
        sortBy: String,
        sortOrder: String,
        limit: Int,
        startIndex: Int
    ) async throws -> (items: [MediaItem], totalCount: Int) {
        // Map sort parameters to Plex format
        let plexSort = mapSortField(sortBy, order: sortOrder)
        let result = try await client.getLibraryItems(
            sectionKey: parentId,
            sort: plexSort,
            start: startIndex,
            size: limit
        )
        return (result.items.map { mapItem($0) }, result.totalSize)
    }

    func getSeasons(seriesId: String) async throws -> [MediaItem] {
        let children = try await client.getChildren(ratingKey: seriesId)
        return children.filter { $0.type == "season" }.map { mapItem($0) }
    }

    func getEpisodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
        let parentKey = seasonId ?? seriesId
        let children = try await client.getChildren(ratingKey: parentKey)
        return children.filter { $0.type == "episode" }.map { mapItem($0) }
    }

    func search(query: String, limit: Int) async throws -> [MediaItem] {
        let items = try await client.search(query: query)
        return Array(items.prefix(limit).map { mapItem($0) })
    }

    // MARK: - Playback

    func getStreamInfo(itemId: String, quality: PlaybackQuality) async throws -> StreamInfo {
        let metadata = try await client.getItem(ratingKey: itemId)

        guard let media = metadata.Media?.first,
              let part = media.Part?.first else {
            throw PlexError.invalidResponse
        }

        guard let url = await client.streamURL(partKey: part.key) else {
            throw PlexError.invalidURL
        }

        let audioStreams: [StreamInfo.AudioStream] = (part.Stream ?? [])
            .filter { $0.streamType == 2 }
            .map { stream in
                StreamInfo.AudioStream(
                    id: "\(stream.id)",
                    index: stream.index ?? 0,
                    codec: stream.codec,
                    language: stream.language,
                    displayTitle: stream.displayTitle,
                    channels: stream.channels,
                    isDefault: stream.selected ?? false
                )
            }

        let subtitleStreams: [StreamInfo.SubtitleStream] = (part.Stream ?? [])
            .filter { $0.streamType == 3 }
            .map { stream in
                StreamInfo.SubtitleStream(
                    id: "\(stream.id)",
                    index: stream.index ?? 0,
                    codec: stream.codec,
                    language: stream.language,
                    displayTitle: stream.displayTitle,
                    isDefault: stream.selected ?? false,
                    isExternal: false
                )
            }

        return StreamInfo(
            url: url,
            isTranscoding: false, // Direct play for now
            container: media.container,
            videoCodec: media.videoCodec,
            videoResolution: media.videoResolution,
            audioCodec: media.audioCodec,
            audioChannels: media.audioChannels,
            playSessionId: nil,
            audioStreams: audioStreams,
            subtitleStreams: subtitleStreams
        )
    }

    func reportPlaybackStart(itemId: String, positionSeconds: Double) async throws {
        let timeMs = Int(positionSeconds * 1000)
        // Use a reasonable default duration; the timeline endpoint requires it
        let item = try await client.getItem(ratingKey: itemId)
        let durationMs = item.duration ?? 0
        try await client.reportTimeline(
            ratingKey: itemId,
            state: "playing",
            timeMs: timeMs,
            durationMs: durationMs
        )
    }

    func reportPlaybackProgress(itemId: String, positionSeconds: Double, isPaused: Bool) async throws {
        let timeMs = Int(positionSeconds * 1000)
        let item = try await client.getItem(ratingKey: itemId)
        let durationMs = item.duration ?? 0
        let state = isPaused ? "paused" : "playing"
        try await client.reportTimeline(
            ratingKey: itemId,
            state: state,
            timeMs: timeMs,
            durationMs: durationMs
        )
    }

    func reportPlaybackStopped(itemId: String, positionSeconds: Double) async throws {
        let timeMs = Int(positionSeconds * 1000)
        let item = try await client.getItem(ratingKey: itemId)
        let durationMs = item.duration ?? 0
        try await client.reportTimeline(
            ratingKey: itemId,
            state: "stopped",
            timeMs: timeMs,
            durationMs: durationMs
        )
    }

    // MARK: - User Actions

    func markPlayed(itemId: String) async throws {
        try await client.scrobble(ratingKey: itemId)
    }

    func markUnplayed(itemId: String) async throws {
        try await client.unscrobble(ratingKey: itemId)
    }

    func setFavorite(itemId: String, isFavorite: Bool) async throws {
        // Plex doesn't have a direct favorite API - no-op
    }

    // MARK: - Images

    func imageURL(itemId: String, type: ImageType, maxWidth: Int) -> URL? {
        let path: String
        switch type {
        case .primary, .thumb:
            path = "/library/metadata/\(itemId)/thumb"
        case .backdrop:
            path = "/library/metadata/\(itemId)/art"
        }
        return client.imageURL(path: path, maxWidth: maxWidth)
    }

    func userImageURL(maxWidth: Int) -> URL? {
        nil
    }

    // MARK: - Mapping Helpers

    private func mapItem(_ metadata: PlexMetadata) -> MediaItem {
        let durationSeconds = metadata.duration.map { Double($0) / 1000.0 }
        let positionSeconds = metadata.viewOffset.map { Double($0) / 1000.0 }

        let playedPercentage: Double?
        if let position = positionSeconds, let duration = durationSeconds, duration > 0 {
            playedPercentage = (position / duration) * 100.0
        } else {
            playedPercentage = nil
        }

        let isPlayed = (metadata.viewCount ?? 0) > 0

        let itemType = mapItemType(metadata.type)

        // Determine series ID: for episodes use grandparentRatingKey, for seasons use parentRatingKey
        let seriesId: String?
        switch itemType {
        case .episode:
            seriesId = metadata.grandparentRatingKey
        case .season:
            seriesId = metadata.parentRatingKey
        default:
            seriesId = nil
        }

        // Season ID for episodes
        let seasonId: String?
        if itemType == .episode {
            seasonId = metadata.parentRatingKey
        } else {
            seasonId = nil
        }

        let hasSubtitles = metadata.Media?.first?.Part?.first?.Stream?.contains { $0.streamType == 3 } ?? false

        return MediaItem(
            id: "\(id):\(metadata.ratingKey)",
            serverId: id,
            rawId: metadata.ratingKey,
            title: metadata.title,
            type: itemType,
            overview: metadata.summary,
            durationSeconds: durationSeconds,
            playbackPositionSeconds: positionSeconds,
            playedPercentage: playedPercentage,
            isPlayed: isPlayed,
            isFavorite: false, // Plex doesn't expose favorites in metadata
            communityRating: metadata.audienceRating,
            criticRating: nil,
            officialRating: metadata.contentRating,
            genres: metadata.Genre?.map(\.tag) ?? [],
            year: metadata.year,
            seriesId: seriesId,
            seasonId: seasonId,
            seasonNumber: metadata.parentIndex,
            episodeNumber: metadata.index,
            seriesName: metadata.grandparentTitle,
            parentId: metadata.parentRatingKey,
            unplayedCount: nil,
            hasSubtitles: hasSubtitles,
            primaryImageAspectRatio: nil,
            imageItemId: metadata.ratingKey,
            backdropItemId: metadata.grandparentRatingKey ?? metadata.ratingKey,
            premiereDate: nil,
            lastPlayedDate: nil,
            parentBackdropImageTags: nil,
            backdropImageTags: nil,
            path: nil
        )
    }

    private func mapItemType(_ type: String) -> MediaItemType {
        switch type {
        case "movie": return .movie
        case "show": return .series
        case "season": return .season
        case "episode": return .episode
        default: return .video
        }
    }

    private func mapLibrary(_ library: PlexLibrary) -> MediaLibrary {
        MediaLibrary(
            id: "\(id):\(library.key)",
            serverId: id,
            rawId: library.key,
            name: library.title,
            type: mapLibraryType(library.type),
            collectionType: library.type
        )
    }

    private func mapLibraryType(_ type: String) -> LibraryType {
        switch type {
        case "movie": return .movies
        case "show": return .tvShows
        case "artist": return .music
        default: return .other
        }
    }

    private func mapSortField(_ sortBy: String, order: String) -> String {
        // Map common Jellyfin sort fields to Plex equivalents
        let field: String
        switch sortBy.lowercased() {
        case "sortname", "name": field = "titleSort"
        case "datecreated": field = "addedAt"
        case "premieredate": field = "originallyAvailableAt"
        case "communityrating": field = "audienceRating"
        case "runtime": field = "duration"
        default: field = "titleSort"
        }

        let direction = order.lowercased() == "descending" ? ":desc" : ":asc"
        return field + direction
    }
}
