import Foundation

/// Which episodes a bulk download action covers. The titles are shared
/// wording with the Android client, so keep them in step.
enum BulkDownloadScope: Equatable {
    /// Every episode of the series, specials included.
    case series
    /// Every unwatched regular episode of the series (specials excluded).
    case seriesUnwatched
    /// Every episode of the selected season.
    case season
    /// Every unwatched episode of the selected season.
    case seasonUnwatched
    /// The next `n` unwatched episodes of the selected season.
    case nextUnwatched(Int)

    var title: String {
        switch self {
        case .series: return "Download Series"
        case .seriesUnwatched: return "Download Unwatched"
        case .season: return "Download Season"
        case .seasonUnwatched: return "Download Unwatched in Season"
        case .nextUnwatched: return "Custom..."
        }
    }

    /// Series scopes span every season, so their episodes must be fetched;
    /// season scopes use the episodes the page already shows.
    var isUnwatchedOnly: Bool {
        switch self {
        case .seriesUnwatched, .seasonUnwatched, .nextUnwatched: return true
        case .series, .season: return false
        }
    }

    var spansSeries: Bool {
        switch self {
        case .series, .seriesUnwatched: return true
        case .season, .seasonUnwatched, .nextUnwatched: return false
        }
    }
}

/// Pure rules behind the series/season bulk download actions: which episodes
/// a scope selects, which of those still need queueing, when to confirm and
/// how big the batch is likely to be.
enum BulkDownloadPlanner {
    /// Batches larger than this ask for confirmation before queueing.
    static let confirmationThreshold = 10

    static func isSpecial(_ episode: BaseItemDto) -> Bool {
        episode.parentIndexNumber == 0
    }

    static func isUnwatched(_ episode: BaseItemDto) -> Bool {
        !(episode.userData?.played ?? false)
    }

    /// Unwatched regular episodes across the whole series: specials (season 0)
    /// are left out, as is anything the user has already played.
    static func unwatchedRegularEpisodes(_ episodes: [BaseItemDto]) -> [BaseItemDto] {
        episodes.filter { !isSpecial($0) && isUnwatched($0) }
    }

    /// The episodes `scope` selects from `episodes`, in their original order.
    static func select(_ scope: BulkDownloadScope, from episodes: [BaseItemDto]) -> [BaseItemDto] {
        switch scope {
        case .series, .season:
            return episodes
        case .seriesUnwatched:
            return unwatchedRegularEpisodes(episodes)
        case .seasonUnwatched:
            return episodes.filter(isUnwatched)
        case .nextUnwatched(let count):
            return Array(episodes.filter(isUnwatched).prefix(max(count, 0)))
        }
    }

    /// True when an existing record means the item must not be queued again.
    /// Failed and paused records are re-queued, as the manager already allows.
    static func isAlreadyTracked(_ status: DownloadStatus?) -> Bool {
        switch status {
        case .completed, .queued, .preparing, .downloading: return true
        case .failed, .paused, nil: return false
        }
    }

    /// Drops episodes already downloaded, queued or downloading, and any
    /// duplicate IDs, keeping the original order.
    static func pending(
        _ episodes: [BaseItemDto],
        status: (String) -> DownloadStatus?
    ) -> [BaseItemDto] {
        var seen = Set<String>()
        return episodes.filter { episode in
            guard seen.insert(episode.id).inserted else { return false }
            return !isAlreadyTracked(status(episode.id))
        }
    }

    static func needsConfirmation(count: Int) -> Bool {
        count > confirmationThreshold
    }

    /// Size estimate from runtime x the quality's bitrate cap. Nil for
    /// Original (no cap to estimate from) or when no episode has a runtime.
    static func estimatedBytes(for episodes: [BaseItemDto], quality: DownloadQuality) -> Int64? {
        guard let bitrate = quality.maxBitrate else { return nil }
        let ticks = episodes.compactMap(\.runTimeTicks).filter { $0 > 0 }
        guard !ticks.isEmpty else { return nil }
        let seconds = Double(ticks.reduce(0, +)) / 10_000_000
        return Int64(seconds * Double(bitrate) / 8)
    }

    /// "Download 24 episodes (~18 GB)?", or without the size when unknown.
    static func confirmationTitle(count: Int, estimatedBytes: Int64?) -> String {
        let noun = count == 1 ? "episode" : "episodes"
        guard let estimatedBytes, estimatedBytes > 0 else {
            return "Download \(count) \(noun)?"
        }
        let size = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
        return "Download \(count) \(noun) (~\(size))?"
    }
}
