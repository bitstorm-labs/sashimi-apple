import Foundation

/// The pure rules behind the detail-screen hero trailer (#658), kept apart from
/// `HeroTrailerController`'s AVPlayer plumbing so every decision is unit-testable.
enum HeroTrailerPolicy {
    /// The item whose local trailer plays in this screen's hero, or nil when
    /// the screen never plays one.
    ///
    /// Seasons and episodes use their series' trailer: episodes have no
    /// trailers of their own, and a clip cut from the episode itself would
    /// risk spoilers. A movie or series that the server says has no local
    /// trailer is skipped here, without a request.
    static func trailerSourceId(for item: BaseItemDto) -> String? {
        switch item.type {
        case .movie, .series:
            if let count = item.localTrailerCount, count == 0 { return nil }
            return item.id
        case .season, .episode:
            return item.seriesId
        default:
            return nil
        }
    }

    /// What decides whether a trailer may start at all right now.
    struct Conditions {
        var settingOn: Bool
        var isOnline: Bool
        var isExpensive: Bool
        var isConstrained: Bool
        var screenServerId: String?
        var activeServerId: String?

        /// Offline there's nothing to stream; on a metered or Low Data network
        /// a 20 MB background video nobody asked for is the wrong trade; and a
        /// detail screen for a server that isn't the active one can't be
        /// streamed through `JellyfinClient`, which only talks to the active
        /// server.
        var isEligible: Bool {
            guard settingOn, isOnline, !isExpensive, !isConstrained else { return false }
            if let screenServerId, screenServerId != activeServerId { return false }
            return true
        }
    }

    /// Option "1 maybe 3": the trailer is silent while a theme song plays and
    /// has its own sound otherwise.
    static func shouldMute(themeIsPlaying: Bool) -> Bool {
        themeIsPlaying
    }
}

/// A playable hero-trailer stream and the server session behind it.
struct HeroTrailerStream: Equatable, Sendable {
    static let maxBitrate = 4_000_000
    static let maxWidth = 1280

    let url: URL
    /// Nil when the server didn't report one; the encoding then simply ends on
    /// the server's idle timeout.
    let playSessionId: String?
}

/// Which detail screen owns the hero trailer.
///
/// Detail screens are presented with `fullScreenCover` on tvOS, so a covered
/// screen is never removed and its `onDisappear` never fires (see
/// `ThemeSongPlayer`). The newest screen on top owns the single player. A
/// trailer plays at most once per source per visit: drilling from a series
/// into its season hands the running trailer over instead of restarting it,
/// and a trailer that already finished doesn't play again until every detail
/// screen has been dismissed.
struct HeroTrailerOwners {
    enum Decision: Equatable {
        /// Start the trailer for this source in the top screen.
        case start(sourceId: String)
        /// Keep the running trailer; it now shows in the top screen.
        case handOff
        /// Stop whatever is playing; the top screen shows its image.
        case stop
        /// Nothing changes.
        case ignore
    }

    private struct Entry {
        let owner: UUID
        let sourceId: String?
    }

    private var stack: [Entry] = []
    private var played: Set<String> = []

    /// The screen that should currently show the trailer.
    var topOwner: UUID? { stack.last?.owner }

    mutating func appeared(owner: UUID, sourceId: String?, playingSourceId: String?) -> Decision {
        stack.removeAll { $0.owner == owner }
        stack.append(Entry(owner: owner, sourceId: sourceId))
        guard let sourceId else { return .stop }
        if sourceId == playingSourceId { return .handOff }
        if played.contains(sourceId) { return .stop }
        played.insert(sourceId)
        return .start(sourceId: sourceId)
    }

    mutating func dismissed(owner: UUID, playingSourceId: String?) -> Decision {
        guard let index = stack.firstIndex(where: { $0.owner == owner }) else { return .ignore }
        let wasTop = index == stack.count - 1
        stack.remove(at: index)
        guard let top = stack.last else {
            played = []
            return .stop
        }
        guard wasTop else { return .ignore }
        if let playingSourceId, top.sourceId == playingSourceId { return .handOff }
        return .stop
    }

    mutating func reset() {
        stack = []
        played = []
    }
}
