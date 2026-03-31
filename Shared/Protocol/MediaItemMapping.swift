import Foundation

/// Shared utility for mapping BaseItemDto to MediaItem.
/// Used by views that call JellyfinClient directly and need to present results as MediaItem.
@MainActor
enum MediaItemMapper {
    static func map(_ dto: BaseItemDto, serverId: String? = nil) -> MediaItem {
        let sid = serverId ?? ServerManager.shared.primaryServer?.id ?? ""
        let durationSeconds = dto.runTimeTicks.map { Double($0) / 10_000_000 }
        let positionSeconds = dto.userData?.playbackPositionTicks.map { Double($0) / 10_000_000 }
        let playedPercentage: Double?
        if let pos = positionSeconds, let dur = durationSeconds, dur > 0 {
            playedPercentage = (pos / dur) * 100.0
        } else {
            playedPercentage = nil
        }

        return MediaItem(
            id: "\(sid):\(dto.id)",
            serverId: sid,
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

    static func mapMany(_ dtos: [BaseItemDto], serverId: String? = nil) -> [MediaItem] {
        dtos.map { map($0, serverId: serverId) }
    }

    private static func mapItemType(_ type: ItemType?) -> MediaItemType {
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
}
