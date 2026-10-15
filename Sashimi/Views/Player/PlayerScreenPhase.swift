import Foundation

/// What the tvOS player shows full screen, in one place so that every
/// combination of view-model state maps to something on screen.
///
/// The body used to be an `if/else if` chain with no final `else`: no player,
/// not loading, no Up Next and no error drew nothing over the black backdrop.
/// `loadMedia` passed through exactly that state while it stopped the old
/// transcode, so starting the next episode flashed Up Next → black → spinner
/// → player.
enum PlayerScreenPhase: Equatable {
    case loading
    case error
    case upNext
    case playing

    static func resolve(
        isLoading: Bool,
        hasError: Bool,
        hasEpisodeUpNext: Bool,
        hasPlayer: Bool
    ) -> PlayerScreenPhase {
        if isLoading { return .loading }
        if hasError { return .error }
        if hasEpisodeUpNext { return .upNext }
        if hasPlayer { return .playing }
        // Between players (one torn down, the next not built): still loading.
        return .loading
    }

    /// Whether the loading screen stays over a player that is already up.
    ///
    /// A new `AVPlayerViewController` is black until its first frame, which
    /// on a Jellyfin transcode is the seconds ffmpeg takes to produce a
    /// segment. Showing it the moment loading ended swapped our spinner for a
    /// black AVKit screen and then the picture — a second flicker. The cover
    /// holds until the first frame is ready, or until `gaveUp` (a stream with
    /// no video track never reports one).
    static func coversPlayer(phase: PlayerScreenPhase, isReadyForDisplay: Bool, gaveUp: Bool) -> Bool {
        phase == .playing && !isReadyForDisplay && !gaveUp
    }
}
