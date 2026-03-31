import Foundation

// MARK: - JellyfinServer

/// Wraps the existing JellyfinClient actor to conform to the MediaServer protocol.
/// Thread safety is handled by the underlying JellyfinClient actor.
final class JellyfinServer: MediaServer, @unchecked Sendable {
    let id: String
    let name: String
    let serverType: ServerType = .jellyfin
    let serverURL: URL

    private let client: JellyfinClient
    private let userId: String

    private static let ticksPerSecond: Double = 10_000_000

    init(account: ServerAccount, client: JellyfinClient = .shared) {
        self.id = account.id
        self.name = account.serverName
        self.serverURL = account.serverURL
        self.userId = account.userId
        self.client = client
    }

    // MARK: - Libraries

    func getLibraries() async throws -> [MediaLibrary] {
        let libraries = try await client.getLibraryViews()
        return libraries.map { mapLibrary($0) }
    }

    // MARK: - Items

    func getResumeItems(limit: Int) async throws -> [MediaItem] {
        let items = try await client.getResumeItems(limit: limit)
        return items.map { mapItem($0) }
    }

    func getNextUp(limit: Int) async throws -> [MediaItem] {
        let items = try await client.getNextUp(limit: limit)
        return items.map { mapItem($0) }
    }

    func getLatestMedia(libraryId: String?, limit: Int) async throws -> [MediaItem] {
        let items = try await client.getLatestMedia(parentId: libraryId, limit: limit)
        return items.map { mapItem($0) }
    }

    func getItem(id: String) async throws -> MediaItem {
        let dto = try await client.getItem(itemId: id)
        return mapItem(dto)
    }

    // Parameter count matches the MediaServer protocol requirement
    func getChildren( // swiftlint:disable:this function_parameter_count
        parentId: String,
        type: MediaItemType?,
        sortBy: String,
        sortOrder: String,
        limit: Int,
        startIndex: Int
    ) async throws -> (items: [MediaItem], totalCount: Int) {
        let includeTypes: [ItemType]? = type.flatMap { mapToItemTypes($0) }
        let response = try await client.getItems(
            parentId: parentId,
            includeTypes: includeTypes,
            sortBy: sortBy,
            sortOrder: sortOrder,
            limit: limit,
            startIndex: startIndex
        )
        return (response.items.map { mapItem($0) }, response.totalRecordCount)
    }

    func getSeasons(seriesId: String) async throws -> [MediaItem] {
        let items = try await client.getSeasons(seriesId: seriesId)
        return items.map { mapItem($0) }
    }

    func getEpisodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
        let items = try await client.getEpisodes(seriesId: seriesId, seasonId: seasonId)
        return items.map { mapItem($0) }
    }

    func search(query: String, limit: Int) async throws -> [MediaItem] {
        let items = try await client.search(query: query, limit: limit)
        return items.map { mapItem($0) }
    }

    // MARK: - Playback

    func getStreamInfo(itemId: String, quality: PlaybackQuality) async throws -> StreamInfo {
        let response = try await client.getPlaybackInfo(itemId: itemId, maxBitrate: quality.maxBitrate)

        guard let source = response.mediaSources?.first else {
            throw JellyfinError.invalidResponse
        }

        let url: URL
        let isTranscoding: Bool

        if let transcodingPath = source.transcodingUrl,
           let transcodingURL = await client.buildURL(path: transcodingPath) {
            url = transcodingURL
            isTranscoding = true
        } else if let directPath = source.directStreamUrl,
                  let directURL = await client.buildURL(path: directPath) {
            url = directURL
            isTranscoding = false
        } else if let fallbackURL = await client.getPlaybackURL(
            itemId: itemId,
            mediaSourceId: source.id,
            container: source.container
        ) {
            url = fallbackURL
            isTranscoding = false
        } else {
            throw JellyfinError.invalidURL
        }

        let audioStreams = source.audioStreams.map { stream in
            StreamInfo.AudioStream(
                id: "\(stream.index ?? 0)",
                index: stream.index ?? 0,
                codec: stream.codec,
                language: stream.language,
                displayTitle: stream.displayTitle,
                channels: stream.channels,
                isDefault: stream.isDefault ?? false
            )
        }

        let subtitleStreams = source.subtitleStreams.map { stream in
            StreamInfo.SubtitleStream(
                id: "\(stream.index ?? 0)",
                index: stream.index ?? 0,
                codec: stream.codec,
                language: stream.language,
                displayTitle: stream.displayTitle,
                isDefault: stream.isDefault ?? false,
                isExternal: stream.isExternal ?? false
            )
        }

        return StreamInfo(
            url: url,
            isTranscoding: isTranscoding,
            container: source.container,
            videoCodec: source.videoCodec,
            videoResolution: source.videoResolution,
            audioCodec: source.audioCodec,
            audioChannels: source.audioChannels,
            playSessionId: response.playSessionId,
            audioStreams: audioStreams,
            subtitleStreams: subtitleStreams
        )
    }

    func reportPlaybackStart(itemId: String, positionSeconds: Double) async throws {
        let ticks = secondsToTicks(positionSeconds)
        try await client.reportPlaybackStart(itemId: itemId, positionTicks: ticks)
    }

    func reportPlaybackProgress(itemId: String, positionSeconds: Double, isPaused: Bool) async throws {
        let ticks = secondsToTicks(positionSeconds)
        try await client.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, isPaused: isPaused)
    }

    func reportPlaybackStopped(itemId: String, positionSeconds: Double) async throws {
        let ticks = secondsToTicks(positionSeconds)
        try await client.reportPlaybackStopped(itemId: itemId, positionTicks: ticks)
    }

    // MARK: - User Actions

    func markPlayed(itemId: String) async throws {
        try await client.markPlayed(itemId: itemId)
    }

    func markUnplayed(itemId: String) async throws {
        try await client.markUnplayed(itemId: itemId)
    }

    func setFavorite(itemId: String, isFavorite: Bool) async throws {
        if isFavorite {
            try await client.markFavorite(itemId: itemId)
        } else {
            try await client.removeFavorite(itemId: itemId)
        }
    }

    func deleteItem(itemId: String) async throws {
        try await client.deleteItem(itemId: itemId)
    }

    func refreshMetadata(itemId: String) async throws {
        try await client.refreshMetadata(itemId: itemId)
    }

    // MARK: - Images

    func imageURL(itemId: String, type: ImageType, maxWidth: Int) -> URL? {
        client.syncImageURL(itemId: itemId, imageType: type.rawValue, maxWidth: maxWidth)
    }

    func userImageURL(maxWidth: Int) -> URL? {
        client.userImageURL(userId: userId, maxWidth: maxWidth)
    }

    // MARK: - Mapping Helpers

    private func mapItem(_ dto: BaseItemDto) -> MediaItem {
        let durationSeconds = dto.runTimeTicks.map { ticksToSeconds($0) }
        let positionSeconds = dto.userData?.playbackPositionTicks.map { ticksToSeconds($0) }

        let playedPercentage: Double?
        if let position = positionSeconds, let duration = durationSeconds, duration > 0 {
            playedPercentage = (position / duration) * 100.0
        } else {
            playedPercentage = nil
        }

        return MediaItem(
            id: "\(id):\(dto.id)",
            serverId: id,
            rawId: dto.id,
            title: dto.name,
            type: mapItemType(dto.type),
            overview: dto.overview,
            durationSeconds: durationSeconds,
            playbackPositionSeconds: positionSeconds,
            playedPercentage: playedPercentage,
            isPlayed: dto.userData?.played ?? false,
            isFavorite: dto.userData?.isFavorite ?? false,
            communityRating: dto.communityRating,
            criticRating: dto.criticRating,
            officialRating: dto.officialRating,
            genres: dto.genres ?? [],
            year: dto.productionYear,
            seriesId: dto.seriesId,
            seasonId: dto.seasonId,
            seasonNumber: dto.parentIndexNumber,
            episodeNumber: dto.indexNumber,
            seriesName: dto.seriesName,
            parentId: dto.parentId,
            unplayedCount: dto.userData?.unplayedItemCount,
            hasSubtitles: false,
            primaryImageAspectRatio: dto.primaryImageAspectRatio,
            imageItemId: dto.id,
            backdropItemId: dto.seriesId ?? dto.id,
            premiereDate: dto.premiereDate,
            lastPlayedDate: dto.userData?.lastPlayedDate,
            parentBackdropImageTags: dto.parentBackdropImageTags,
            backdropImageTags: dto.backdropImageTags,
            path: dto.path
        )
    }

    private func mapItemType(_ type: ItemType?) -> MediaItemType {
        switch type {
        case .movie: return .movie
        case .series: return .series
        case .season: return .season
        case .episode: return .episode
        case .video: return .video
        case .boxSet: return .collection
        case .folder, .collectionFolder: return .folder
        case .unknown, .none: return .video
        }
    }

    private func mapToItemTypes(_ type: MediaItemType) -> [ItemType]? {
        switch type {
        case .movie: return [.movie]
        case .series: return [.series]
        case .season: return [.season]
        case .episode: return [.episode]
        case .video: return [.video]
        case .collection: return [.boxSet]
        case .folder: return [.folder, .collectionFolder]
        }
    }

    private func mapLibrary(_ library: JellyfinLibrary) -> MediaLibrary {
        MediaLibrary(
            id: "\(id):\(library.id)",
            serverId: id,
            rawId: library.id,
            name: library.name,
            type: mapLibraryType(library.collectionType),
            collectionType: library.collectionType
        )
    }

    private func mapLibraryType(_ collectionType: String?) -> LibraryType {
        switch collectionType?.lowercased() {
        case "movies": return .movies
        case "tvshows": return .tvShows
        case "music": return .music
        default: return .other
        }
    }

    // MARK: - Tick Conversion

    private func ticksToSeconds(_ ticks: Int64) -> Double {
        Double(ticks) / Self.ticksPerSecond
    }

    private func secondsToTicks(_ seconds: Double) -> Int64 {
        Int64(seconds * Self.ticksPerSecond)
    }
}
