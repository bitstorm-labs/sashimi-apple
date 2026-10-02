import Foundation

/// Watched / in-progress rules for media played from a download, where the
/// server's own played flag is not available.
enum OfflinePlaybackRules {
    /// Jellyfin's default MaxResumePct: past this share of the runtime the
    /// server marks an item played instead of saving a resume point, so the
    /// same line decides "watched" offline.
    static let playedFraction = 0.9

    static func isPlayed(positionTicks: Int64, runTimeTicks: Int64?) -> Bool {
        guard let runTimeTicks, runTimeTicks > 0, positionTicks > 0 else { return false }
        return Double(positionTicks) >= Double(runTimeTicks) * playedFraction
    }

    static func isInProgress(positionTicks: Int64, runTimeTicks: Int64?) -> Bool {
        positionTicks > 0 && !isPlayed(positionTicks: positionTicks, runTimeTicks: runTimeTicks)
    }
}

/// The plain values the offline ordering needs from a downloaded episode.
/// Deliberately free of SwiftData so the rules are testable from the tvOS
/// test host.
struct OfflineEpisodeKey: Equatable {
    let id: String
    /// Groups episodes into one show (series id, or name for old records).
    let seriesKey: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    var isPlayed = false
    var isInProgress = false

    fileprivate var isOrderable: Bool {
        seasonNumber != nil && episodeNumber != nil
    }
}

/// Series order over the downloaded episodes only: what plays next offline,
/// what Next Up offers, and what a show page's Play button starts.
enum OfflineEpisodeOrder {
    /// Episodes of one show in season/episode order. Episodes without both
    /// numbers can't be placed and are left out; duplicates keep the first.
    static func sorted(_ episodes: [OfflineEpisodeKey]) -> [OfflineEpisodeKey] {
        var seen = Set<String>()
        return episodes
            .filter { $0.isOrderable && seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let left = (lhs.seasonNumber ?? 0, lhs.episodeNumber ?? 0)
                let right = (rhs.seasonNumber ?? 0, rhs.episodeNumber ?? 0)
                return left == right ? lhs.id < rhs.id : left < right
            }
    }

    /// The downloaded episodes either side of `currentID` in its show. Only
    /// episodes of the current one's show are considered; nil when the
    /// current episode is not among `episodes` or can't be ordered.
    static func adjacent(
        to currentID: String,
        in episodes: [OfflineEpisodeKey]
    ) -> (previous: OfflineEpisodeKey?, next: OfflineEpisodeKey?) {
        guard let current = episodes.first(where: { $0.id == currentID }) else { return (nil, nil) }
        let show = sorted(episodes.filter { $0.seriesKey == current.seriesKey })
        guard let index = show.firstIndex(where: { $0.id == currentID }) else { return (nil, nil) }
        let previous = index > show.startIndex ? show[index - 1] : nil
        let next = index + 1 < show.endIndex ? show[index + 1] : nil
        return (previous, next)
    }

    /// Next Up from downloads: per show the viewer has started (something is
    /// played), the first unplayed episode after the furthest played one.
    /// Shows with an episode in progress are left to Continue Watching, as are
    /// shows not started at all. Shows keep the order they first appear in.
    static func nextUp(in episodes: [OfflineEpisodeKey]) -> [OfflineEpisodeKey] {
        var showOrder: [String] = []
        var byShow: [String: [OfflineEpisodeKey]] = [:]
        for episode in episodes {
            if byShow[episode.seriesKey] == nil {
                showOrder.append(episode.seriesKey)
            }
            byShow[episode.seriesKey, default: []].append(episode)
        }
        return showOrder.compactMap { key in
            let show = sorted(byShow[key] ?? [])
            guard !show.contains(where: \.isInProgress),
                  let lastPlayed = show.lastIndex(where: \.isPlayed) else { return nil }
            return show[(lastPlayed + 1)...].first { !$0.isPlayed }
        }
    }

    /// What a show page's Play / Resume button starts: the episode in
    /// progress (the furthest one, if several), else the Next Up episode, else
    /// the first unplayed episode, else the first episode.
    static func playTarget(in episodes: [OfflineEpisodeKey]) -> OfflineEpisodeKey? {
        let show = sorted(episodes)
        if let inProgress = show.last(where: \.isInProgress) {
            return inProgress
        }
        if let next = nextUp(in: show).first {
            return next
        }
        return show.first { !$0.isPlayed } ?? show.first
    }
}
