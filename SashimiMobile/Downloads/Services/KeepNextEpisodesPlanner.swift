import Foundation

/// The choices offered for "Keep next episodes downloaded". 0 is Off.
enum KeepNextEpisodesOption {
    static let counts = [1, 3, 5]

    /// "Keeping next 3" for the Downloads show header.
    static func keepingTitle(_ count: Int) -> String {
        "Keeping next \(count)"
    }

    static func countTitle(_ count: Int) -> String {
        count == 1 ? "Next episode" : "Next \(count) episodes"
    }
}

/// Pure rules behind "Keep next episodes downloaded": given a show's episodes
/// in order and what is on the device, which downloads to delete and which
/// episodes to queue so the next `count` unwatched episodes stay downloaded.
enum KeepNextEpisodesPlanner {
    /// One episode of the show, in the server's season/episode order.
    struct Episode: Equatable {
        let id: String
        /// Season 0. Specials are never part of the window.
        let isSpecial: Bool
        /// The server's Played flag.
        let isPlayed: Bool
        /// When the server last saw it played (Jellyfin's LastPlayedDate).
        let lastPlayedDate: Date?
    }

    /// A download record of one of the show's episodes, any status.
    struct Download: Equatable {
        let itemId: String
        let dateAdded: Date
        /// Played to the end offline, so the server may not know yet.
        let isWatchedLocally: Bool
    }

    struct Plan: Equatable {
        /// Downloads of episodes watched since they were downloaded.
        var delete: [String] = []
        /// Episodes in the window with no download record, in order.
        var enqueue: [String] = []

        var isEmpty: Bool { delete.isEmpty && enqueue.isEmpty }
    }

    static func plan(episodes: [Episode], downloads: [Download], count: Int) -> Plan {
        guard count > 0 else { return Plan() }
        let downloadsByID = Dictionary(downloads.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })

        func isWatched(_ episode: Episode) -> Bool {
            episode.isPlayed || downloadsByID[episode.id]?.isWatchedLocally == true
        }

        // The viewer's position: just after the last watched regular episode,
        // as Jellyfin's Next Up places it. The in-progress episode, if any,
        // sits there and is included.
        let regular = episodes.filter { !$0.isSpecial }
        let start = (regular.lastIndex(where: isWatched)).map { $0 + 1 } ?? 0
        let window = regular[start...].filter { !isWatched($0) }.prefix(count)

        var plan = Plan()
        // Already downloaded, queued, or even failed episodes count toward the
        // window; a failed one is left for the user to retry.
        plan.enqueue = window.map(\.id).filter { downloadsByID[$0] == nil }
        plan.delete = episodes.compactMap { episode in
            guard let download = downloadsByID[episode.id],
                  watchedSinceDownloaded(episode, download) else { return nil }
            return episode.id
        }
        return plan
    }

    /// Only an episode finished after it was downloaded is removed. One the
    /// user downloaded deliberately after watching it (to rewatch it) stays,
    /// as does a played episode with no date to compare.
    static func watchedSinceDownloaded(_ episode: Episode, _ download: Download) -> Bool {
        if download.isWatchedLocally { return true }
        guard episode.isPlayed, let lastPlayed = episode.lastPlayedDate else { return false }
        return lastPlayed > download.dateAdded
    }
}
