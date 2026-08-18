import Foundation

/// Tracks which show the user is currently visiting, so a theme plays once per
/// visit rather than once per screen.
///
/// Detail screens are presented with `fullScreenCover`, not pushed, so
/// Series -> Season -> Episode stacks three live views for one show and the
/// parent's `onDisappear` never fires. Keying on the series — not the screen —
/// is what makes drill-down silent and return-from-player silent with one rule.
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

    mutating func reset() {
        currentSeriesId = nil
        depth = 0
    }
}
