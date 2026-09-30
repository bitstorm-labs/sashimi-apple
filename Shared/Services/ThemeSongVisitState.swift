import Foundation

/// Tracks which show the user is currently visiting, so a theme plays once per
/// visit rather than once per screen.
///
/// Two drivers feed it:
///
/// - iOS reports screens through `showAppeared` / `detailDismissed` (the
///   `.themeSong(for:)` modifier). Those detail screens stack as covers and
///   sheets, so Series -> Season -> Episode stacks three live views for one
///   show and the parent's `onDisappear` never fires; `depth` counts them.
/// - tvOS pushes detail pages onto a `NavigationStack`, where a page that is
///   pushed over DOES disappear. Counting appear/disappear there would lean on
///   SwiftUI's event ordering, so tvOS instead reports the show that owns the
///   whole navigation path through `activate(seriesId:)` — see `DetailRouter`.
///
/// Keying on the series — not the screen — is what makes drill-down silent
/// and return-from-player silent with one rule.
struct ThemeSongVisitState {
    enum Decision: Equatable {
        case start(seriesId: String)
        case stop
        case ignore
    }

    /// The show whose visit is currently active, if any.
    private(set) var currentSeriesId: String?

    /// How many detail screens for `currentSeriesId` are on screen. Drill-down
    /// increments, backing out decrements; the visit ends only at zero.
    private var depth = 0

    mutating func showAppeared(seriesId: String?) -> Decision {
        guard let seriesId else { return .ignore }

        if seriesId == currentSeriesId {
            depth += 1
            return .ignore
        }

        currentSeriesId = seriesId
        depth = 1
        return .start(seriesId: seriesId)
    }

    mutating func detailDismissed(seriesId: String?) -> Decision {
        guard let seriesId, seriesId == currentSeriesId else { return .ignore }

        depth -= 1
        guard depth <= 0 else { return .ignore }

        currentSeriesId = nil
        depth = 0
        return .stop
    }

    /// The show that owns the current navigation path changed (tvOS). Unlike
    /// the appear/dismiss pair this is absolute, not counted: the caller says
    /// which show is on screen now, and `nil` means none is (back at a tab's
    /// root). Re-reporting the same show is ignored, so drilling from a series
    /// into its episodes, or coming back from the player, never restarts it.
    mutating func activate(seriesId: String?) -> Decision {
        guard seriesId != currentSeriesId else { return .ignore }
        guard let seriesId else {
            reset()
            return .stop
        }
        currentSeriesId = seriesId
        depth = 1
        return .start(seriesId: seriesId)
    }

    /// The show a detail screen belongs to: a series is its own key, a season
    /// or episode belongs to its parent series. Anything else (movies, videos,
    /// people) has no key and never plays a theme.
    static func seriesKey(for item: BaseItemDto) -> String? {
        switch item.type {
        case .series: return item.id
        case .season, .episode: return item.seriesId
        default: return nil
        }
    }

    mutating func reset() {
        currentSeriesId = nil
        depth = 0
    }
}
