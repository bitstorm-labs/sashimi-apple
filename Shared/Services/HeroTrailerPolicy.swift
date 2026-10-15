import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    /// Which length rules a screen's trailer follows: a movie's own, or the
    /// series' (seasons and episodes play their series' trailer).
    enum Kind: Equatable, Sendable {
        case movie, series
    }

    static func kind(for item: BaseItemDto) -> Kind {
        item.type == .movie ? .movie : .series
    }

    /// The part of a trailer the hero plays before anything else is known.
    ///
    /// The first seconds of a full trailer are almost always the green rating
    /// card or a studio logo, so they're skipped; a short clip has no such
    /// opening and plays from the start.
    ///
    /// A movie's trailer plays to its natural end; with no known length the
    /// item's own end stops it (`end` is infinite). A series' trailer plays a
    /// short stretch, like Netflix's billboard previews, unless a theme song
    /// is playing: then it ends with the theme (`followingTheme`,
    /// `afterThemeEnded`). The end never runs past the trailer's own end, so
    /// the fade always has a moment of video left to fade.
    static func clip(trailerSeconds: Double?, kind: Kind) -> HeroTrailerClip {
        let start = openingStart(trailerSeconds: trailerSeconds)
        let trailerEnd = trailerSeconds ?? .infinity
        switch kind {
        case .movie:
            return HeroTrailerClip(start: start, end: trailerEnd)
        case .series:
            return HeroTrailerClip(start: start, end: min(start + HeroTrailerClip.length, trailerEnd))
        }
    }

    /// A series' trailer while a theme song plays: it runs until the theme
    /// ends (see `afterThemeEnded`), but never past its own end; a theme that
    /// outlasts the trailer finishes alone.
    static func followingTheme(trailerSeconds: Double?) -> HeroTrailerClip {
        HeroTrailerClip(start: openingStart(trailerSeconds: trailerSeconds), end: trailerSeconds ?? .infinity)
    }

    /// A series' trailer once the theme it followed has ended naturally (or
    /// begun its end fade) with the trailer at `position`: it fades out with
    /// the theme, so the fade starts now and the clip ends `crossFade` later,
    /// but not before the trailer has shown `HeroTrailerClip.seriesMinimum`
    /// seconds of video, and never past its own end.
    static func afterThemeEnded(trailerSeconds: Double?, position: Double, crossFade: Double) -> HeroTrailerClip {
        let start = openingStart(trailerSeconds: trailerSeconds)
        let withTheme = max(position, start) + crossFade
        let end = min(max(withTheme, start + HeroTrailerClip.seriesMinimum), trailerSeconds ?? .infinity)
        return HeroTrailerClip(start: start, end: end)
    }

    private static func openingStart(trailerSeconds: Double?) -> Double {
        guard let trailerSeconds, trailerSeconds >= HeroTrailerClip.minimumForSkip else { return 0 }
        return HeroTrailerClip.openingSkip
    }
}

/// Seconds into the trailer where the hero starts and stops it. An infinite
/// `end` means the trailer's own end, whenever that turns out to be.
struct HeroTrailerClip: Equatable, Sendable {
    static let openingSkip: Double = 10
    /// A series' trailer without a theme song.
    static let length: Double = 30
    /// The least a series' trailer plays when the theme it follows ends early.
    static let seriesMinimum: Double = 20
    static let minimumForSkip: Double = 45

    let start: Double
    let end: Double
}

/// A title's trailer: its item id and, when the server knows it, its length.
struct HeroTrailerSource: Equatable, Sendable {
    let id: String
    let seconds: Double?

    /// The first of a title's local trailers, or nil when it has none.
    init?(trailers: [BaseItemDto]) {
        guard let first = trailers.first else { return nil }
        self.init(id: first.id, seconds: first.runTimeTicks.map { Double($0) / 10_000_000 })
    }

    init(id: String, seconds: Double?) {
        self.id = id
        self.seconds = seconds
    }
}

/// A playable hero-trailer stream and the server session behind it.
struct HeroTrailerStream: Equatable, Sendable {
    /// Where the trailer is shown, which decides how sharp it needs to be.
    enum Screen: Equatable, Sendable {
        case tv, tablet, phone

        @MainActor static var current: Screen {
            #if os(tvOS)
            return .tv
            #else
            return UIDevice.current.userInterfaceIdiom == .phone ? .phone : .tablet
            #endif
        }
    }

    /// The transcode cap. On a TV or tablet the hero is about half the screen,
    /// where 720p reads soft, and most trailers are 1080p; a phone's hero is
    /// small enough that 720p is plenty and saves data.
    static func limits(for screen: Screen) -> (maxBitrate: Int, maxWidth: Int) {
        switch screen {
        case .tv, .tablet: return (8_000_000, 1920)
        case .phone: return (4_000_000, 1280)
        }
    }

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
