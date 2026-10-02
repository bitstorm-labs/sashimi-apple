import Foundation

/// The server's last-known watch state for one downloaded item, as returned in
/// its `UserData`. Codable so the mobile Downloads screen can keep showing it
/// offline after it was last fetched.
struct ServerWatchState: Codable, Hashable, Sendable {
    let played: Bool
    let positionTicks: Int64

    init(played: Bool, positionTicks: Int64) {
        self.played = played
        self.positionTicks = positionTicks
    }

    init(userData: UserItemDataDto?) {
        self.played = userData?.played ?? false
        self.positionTicks = userData?.playbackPositionTicks ?? 0
    }
}

/// What a downloaded row shows: the watched check and/or a progress bar.
struct DownloadWatchState: Hashable, Sendable {
    let isPlayed: Bool
    /// 0...1 fraction for the progress bar; 0 means no bar.
    let progress: Double

    static let unwatched = DownloadWatchState(isPlayed: false, progress: 0)
}

/// One downloaded item reduced to plain values, so this policy can be shared
/// and unit-tested without the iOS-only SwiftData download model.
struct DownloadWatchCandidate: Hashable, Sendable {
    let recordID: String
    let sizeBytes: Int64
    let isComplete: Bool
}

/// Pure decisions behind the Downloads screen's watch marks, "Remove watched"
/// actions and the "Delete downloads after watching" setting.
enum DownloadWatchPolicy {
    /// Jellyfin's default MaxResumePct: past this point an item counts as played.
    static let playedFraction = 0.9

    /// `UserDefaults` key of the "Delete downloads after watching" setting.
    static let deleteAfterWatchingKey = "deleteDownloadsAfterWatching"

    /// Merges the server's state with what was recorded locally during offline
    /// playback. The server is authoritative, except that a local position the
    /// server has not received yet (`localNeedsSync`) is newer than anything it
    /// returned. With no server state (never fetched, offline), the local
    /// position alone decides.
    static func resolve(
        server: ServerWatchState?,
        runTimeTicks: Int64?,
        localPositionTicks: Int64,
        localNeedsSync: Bool
    ) -> DownloadWatchState {
        let localFraction = fraction(localPositionTicks, of: runTimeTicks)

        if let server, !(localNeedsSync && localPositionTicks > 0) {
            let serverFraction = fraction(server.positionTicks, of: runTimeTicks)
            return DownloadWatchState(isPlayed: server.played, progress: barProgress(serverFraction))
        }

        let playedLocally = localFraction >= playedFraction
        let played = playedLocally || (server?.played ?? false)
        return DownloadWatchState(
            isPlayed: played,
            progress: playedLocally ? 0 : barProgress(localFraction)
        )
    }

    /// The completed downloads a "Remove watched" action deletes.
    static func watchedTargets(
        _ candidates: [DownloadWatchCandidate],
        states: [String: DownloadWatchState]
    ) -> [DownloadWatchCandidate] {
        candidates.filter { $0.isComplete && states[$0.recordID]?.isPlayed == true }
    }

    /// Total bytes freed by deleting `candidates`.
    static func totalBytes(_ candidates: [DownloadWatchCandidate]) -> Int64 {
        candidates.reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    /// Whether a download is removed when its playback ends. Only a finished
    /// download that was played to its end qualifies, and only when the user
    /// opted in.
    static func shouldAutoDelete(
        settingEnabled: Bool,
        isCompletedDownload: Bool,
        playedToEnd: Bool
    ) -> Bool {
        settingEnabled && isCompletedDownload && playedToEnd
    }

    private static func fraction(_ ticks: Int64, of runTimeTicks: Int64?) -> Double {
        guard let runTimeTicks, runTimeTicks > 0, ticks > 0 else { return 0 }
        return min(1, Double(ticks) / Double(runTimeTicks))
    }

    /// A bar only for a started, unfinished item.
    private static func barProgress(_ fraction: Double) -> Double {
        fraction > 0 && fraction < 1 ? fraction : 0
    }
}
