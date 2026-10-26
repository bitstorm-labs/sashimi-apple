import Foundation

/// What an episode's download menu (#744) can queue, besides the episode
/// itself. Shared wording and rules with the Android client
/// (sashimi-android `EpisodeDownloadPlanner`), so keep them in step.
enum EpisodeDownloadScope: Equatable {
    /// The tapped episode and the next `n` regular episodes after it.
    case thisAndNext(Int)
    /// Unwatched episodes of the tapped episode's season.
    case unwatchedInSeason
    /// Unwatched regular episodes of the whole series.
    case unwatchedInSeries
}

enum EpisodeDownloadPlanner {
    /// The counts offered for "This and the Next…".
    static let nextCounts = [1, 3, 5, 10]

    /// The episodes `scope` selects for `episode`, from the series' episodes
    /// in airing order, without the ones already downloaded or queued.
    static func select(
        _ scope: EpisodeDownloadScope,
        for episode: BaseItemDto,
        seriesEpisodes: [BaseItemDto],
        status: (String) -> DownloadStatus?
    ) -> [BaseItemDto] {
        switch scope {
        case .thisAndNext(let count):
            return thisAndNext(episode, seriesEpisodes: seriesEpisodes, count: count, status: status)
        case .unwatchedInSeason:
            let season = seriesEpisodes.filter { sameSeason($0, episode) }
            return BulkDownloadPlanner.pending(BulkDownloadPlanner.select(.seasonUnwatched, from: season), status: status)
        case .unwatchedInSeries:
            return BulkDownloadPlanner.pending(BulkDownloadPlanner.select(.seriesUnwatched, from: seriesEpisodes), status: status)
        }
    }

    /// "This and the next N": `episode` plus the `count` regular episodes that
    /// follow it in airing order, crossing into later seasons. Specials
    /// (season 0) are never among the next N, though a tapped special is
    /// itself included. The window is positional: an episode in it that is
    /// already downloaded or queued is skipped, not replaced by one further
    /// on; a failed one is queued again. Watched episodes in it are included.
    static func thisAndNext(
        _ episode: BaseItemDto,
        seriesEpisodes: [BaseItemDto],
        count: Int,
        status: (String) -> DownloadStatus?
    ) -> [BaseItemDto] {
        var seen = Set<String>()
        let ordered = seriesEpisodes.filter { seen.insert($0.id).inserted }
        var window = [episode]
        if let start = ordered.firstIndex(where: { $0.id == episode.id }) {
            window += ordered[(start + 1)...]
                .filter { !BulkDownloadPlanner.isSpecial($0) }
                .prefix(max(count, 0))
        }
        return BulkDownloadPlanner.pending(window, status: status)
    }

    /// "Season 2", or "Specials" for season 0; nil without a season number.
    static func seasonLabel(_ episode: BaseItemDto) -> String? {
        switch episode.parentIndexNumber {
        case nil: return nil
        case 0: return "Specials"
        case let number?: return "Season \(number)"
        }
    }

    /// "S2 E3 · Shooter Ready", the menu's header.
    static func menuTitle(_ episode: BaseItemDto) -> String {
        guard let season = episode.parentIndexNumber, let number = episode.indexNumber else { return episode.name }
        return "S\(season) E\(number) \u{00B7} \(episode.name)"
    }

    /// "Unwatched in Season 2" (or "Unwatched in Specials").
    static func seasonTitle(_ episode: BaseItemDto) -> String {
        seasonLabel(episode).map { "Unwatched in \($0)" } ?? "Unwatched in Season"
    }

    /// "Next episode" / "Next 3 episodes", the Keep Next picker's wording.
    static func nextCountTitle(_ count: Int) -> String {
        KeepNextEpisodesOption.countTitle(count)
    }

    private static func sameSeason(_ lhs: BaseItemDto, _ rhs: BaseItemDto) -> Bool {
        if let left = lhs.seasonId, let right = rhs.seasonId { return left == right }
        return lhs.parentIndexNumber == rhs.parentIndexNumber
    }
}
