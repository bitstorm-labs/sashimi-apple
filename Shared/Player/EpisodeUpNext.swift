import Foundation

/// The full-screen "Up Next" screen shown when an episode finishes.
///
/// Pure state: no timers, no player, no network. `PlayerViewModel` owns one
/// of these while the screen is up and drives it with the clock; both the
/// tvOS and the iOS screens render it. Keeping the rules here (what follows a
/// finished episode, when the countdown runs, what Skip may do) is what lets
/// them be tested without a player.
///
/// Lifecycle: an episode ends → `decide` → `.showUpNext` (countdown running
/// when Auto-play is on) → the countdown reaches zero or Play is pressed
/// (the episode plays), Cancel is pressed (`.cancelled`: Play / Replay /
/// Done), or the player is dismissed (the state is dropped and nothing plays).
struct EpisodeUpNext: Equatable {
    typealias Kind = PlayerTransitionState.EndCard

    /// The ten seconds the viewer has to act before the next episode starts.
    static let countdownDuration: TimeInterval = 10

    enum Countdown: Equatable {
        /// Auto-play is off: the screen waits for Play.
        case off
        case running(deadline: Date)
        /// The app is not active; the remaining time is kept, not spent.
        case paused(remaining: TimeInterval)
        /// The viewer pressed Cancel. Nothing will start on its own.
        case cancelled
    }

    /// What Skip would move to: the episode after the one shown.
    enum Following: Equatable {
        case loading
        case available(BaseItemDto)
        case none
    }

    let kind: Kind
    /// The episode that just finished (artwork for the final / failed cards).
    let finishedItem: BaseItemDto
    /// Local-file playback: artwork and metadata come from the download, and
    /// Skip only moves among downloaded episodes.
    let isOffline: Bool
    /// The episode Play (or the countdown) starts. Nil on the final and
    /// lookup-failed cards.
    private(set) var episode: BaseItemDto?
    private(set) var following: Following
    private(set) var countdown: Countdown
    /// Bumped by every Skip so a view can cross-fade between episodes.
    private(set) var skipCount = 0

    // MARK: - Deciding what follows an episode

    enum Decision: Equatable {
        /// Start `next` now, with no screen. Picture in Picture only: the
        /// viewer cannot see or press a full-screen card from there.
        case autoplayImmediately(BaseItemDto)
        case showUpNext(EpisodeUpNext)
        /// Nothing to offer: the player closes, as before.
        case end
    }

    struct Context {
        var finishedItem: BaseItemDto
        var lookupStatus: PlayerTransitionState.LookupStatus
        var nextEpisode: BaseItemDto?
        var autoPlayNextEpisode: Bool
        /// The "Episode navigation controls" setting. It used to gate every
        /// end card; it now only gates the final / lookup-failed cards, since
        /// the Up Next screen replaces auto-play itself.
        var showsEpisodeNavigationControls: Bool
        var isOffline: Bool
        var isPictureInPicture: Bool
        var now: Date
    }

    static func decide(_ context: Context) -> Decision {
        // Offline, "no next" only means nothing further is downloaded — not
        // that the series is over — so the player closes rather than claim it.
        if context.isOffline && context.nextEpisode == nil {
            return .end
        }
        switch context.lookupStatus {
        case .available:
            guard let next = context.nextEpisode else { return finalCard(context) }
            if context.isPictureInPicture && context.autoPlayNextEpisode {
                return .autoplayImmediately(next)
            }
            return .showUpNext(EpisodeUpNext(
                kind: .nextEpisode,
                finishedItem: context.finishedItem,
                isOffline: context.isOffline,
                episode: next,
                following: .loading,
                countdown: context.autoPlayNextEpisode
                    ? .running(deadline: context.now.addingTimeInterval(countdownDuration))
                    : .off
            ))
        case .failed:
            guard context.showsEpisodeNavigationControls else { return .end }
            return .showUpNext(EpisodeUpNext(
                kind: .lookupFailed,
                finishedItem: context.finishedItem,
                isOffline: context.isOffline,
                episode: nil,
                following: .none,
                countdown: .off
            ))
        default:
            return finalCard(context)
        }
    }

    private static func finalCard(_ context: Context) -> Decision {
        guard context.showsEpisodeNavigationControls else { return .end }
        return .showUpNext(EpisodeUpNext(
            kind: .finalEpisode,
            finishedItem: context.finishedItem,
            isOffline: context.isOffline,
            episode: nil,
            following: .none,
            countdown: .off
        ))
    }

    // MARK: - Countdown

    var isCancelled: Bool { countdown == .cancelled }

    /// The ring and number are on screen.
    var showsCountdown: Bool {
        switch countdown {
        case .running, .paused: return true
        case .off, .cancelled: return false
        }
    }

    var isCountingDown: Bool {
        if case .running = countdown { return true }
        return false
    }

    func remaining(at now: Date) -> TimeInterval? {
        switch countdown {
        case .running(let deadline): return max(0, deadline.timeIntervalSince(now))
        case .paused(let remaining): return remaining
        case .off, .cancelled: return nil
        }
    }

    /// The whole seconds shown inside the ring: 10 … 1, never 0 on screen.
    func displayedSeconds(at now: Date) -> Int? {
        remaining(at: now).map { max(1, Int($0.rounded(.up))) }
    }

    /// How much of the ring is filled, 0 at the start to 1 at zero.
    func progress(at now: Date) -> Double {
        guard let remaining = remaining(at: now) else { return 0 }
        return min(1, max(0, 1 - remaining / Self.countdownDuration))
    }

    /// True once a running countdown has reached zero: play the episode.
    func isExpired(at now: Date) -> Bool {
        guard case .running(let deadline) = countdown, episode != nil else { return false }
        return now >= deadline
    }

    /// Cancel: stop counting. Play, Replay and Done remain.
    mutating func cancel() {
        countdown = .cancelled
    }

    /// The app left the foreground: hold the remaining time.
    mutating func pause(at now: Date) {
        guard case .running = countdown, let remaining = remaining(at: now) else { return }
        countdown = .paused(remaining: remaining)
    }

    /// Back in the foreground: count down what was left.
    mutating func resume(at now: Date) {
        guard case .paused(let remaining) = countdown else { return }
        countdown = .running(deadline: now.addingTimeInterval(remaining))
    }

    // MARK: - Skip

    /// Skip is offered on the Up Next card until Cancel, and hidden once it is
    /// known that nothing comes after the episode shown.
    var showsSkip: Bool {
        kind == .nextEpisode && !isCancelled && following != .none
    }

    var canSkip: Bool {
        guard showsSkip, case .available = following else { return false }
        return true
    }

    /// Moves to the episode after the one shown and restarts the countdown
    /// (when one was counting). The skipped episode is not marked watched:
    /// nothing is reported for it. Returns false when there is nothing to
    /// move to yet.
    @discardableResult
    mutating func skip(at now: Date) -> Bool {
        guard canSkip, case .available(let nextEpisode) = following else { return false }
        episode = nextEpisode
        following = .loading
        skipCount += 1
        switch countdown {
        case .running:
            countdown = .running(deadline: now.addingTimeInterval(Self.countdownDuration))
        case .paused:
            countdown = .paused(remaining: Self.countdownDuration)
        case .off, .cancelled:
            break
        }
        return true
    }

    /// Records what follows `episodeID`. Ignored when the screen has already
    /// moved past that episode (a slow lookup for an earlier Skip).
    mutating func resolveFollowing(_ item: BaseItemDto?, after episodeID: String) {
        guard episode?.id == episodeID, following == .loading else { return }
        following = item.map(Following.available) ?? .none
    }

    // MARK: - Text

    var eyebrow: String {
        switch kind {
        case .nextEpisode, .lookupFailed: return "UP NEXT"
        case .finalEpisode: return "SERIES COMPLETE"
        }
    }

    var title: String {
        switch kind {
        case .nextEpisode: return episode?.name ?? ""
        case .finalEpisode: return "There are no more episodes"
        case .lookupFailed: return "Next episode unavailable"
        }
    }

    /// "S3:E6" for the episode shown (or the finished one on the final card).
    var episodeLabel: String? {
        let item = episode ?? finishedItem
        guard let season = item.parentIndexNumber, let number = item.indexNumber else { return nil }
        return "S\(season):E\(number)"
    }

    /// Series name above the title on the Up Next card.
    var seriesName: String? {
        (episode ?? finishedItem).seriesName
    }

    var runtimeText: String? {
        guard let ticks = episode?.runTimeTicks else { return nil }
        let minutes = Int((Double(ticks) / 10_000_000 / 60).rounded())
        return minutes > 0 ? "\(minutes) min" : nil
    }

    /// The community (TMDb) rating, when the viewer shows review ratings.
    func rating(showReviewRatings: Bool) -> Double? {
        guard showReviewRatings, let rating = episode?.communityRating, rating > 0 else { return nil }
        return rating
    }

    var message: String? {
        switch kind {
        case .nextEpisode:
            let overview = episode?.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
            return overview?.isEmpty == false ? overview : nil
        case .finalEpisode:
            return "You've finished \(finishedItem.seriesName ?? "this series")."
        case .lookupFailed:
            return "The next episode couldn't be loaded. Try again later or replay this episode."
        }
    }

    /// The item whose artwork fills the screen.
    var artworkItem: BaseItemDto {
        episode ?? finishedItem
    }
}
