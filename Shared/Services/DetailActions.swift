import Foundation

/// A button on a detail page's main action row (#760). Navigation (Go to
/// Series / Season) and Add to Channel are not here: they live in More.
enum DetailRowAction: Equatable {
    case play
    case startOver
    case shuffle
    case trailer
    case watched
    case download
    /// Add to List (shared lists): right before More, on movies, shows and
    /// episodes. Never in the More menu (owner decision, 2026-10-27).
    case addToList
    case more

    /// The main row for an item: Play, Start Over (with progress; for a
    /// series, the progress of the episode Play resumes), Shuffle (series),
    /// Trailer (a local trailer, not on episodes), Watched, Download (where
    /// the platform has downloads), Add to List (movies, shows, episodes),
    /// More.
    static func mainRow(
        for itemType: ItemType?,
        hasProgress: Bool,
        hasTrailer: Bool,
        supportsDownloads: Bool,
        supportsLists: Bool = false
    ) -> [DetailRowAction] {
        var row: [DetailRowAction] = [.play]
        if hasProgress { row.append(.startOver) }
        if itemType == .series { row.append(.shuffle) }
        if hasTrailer, itemType != .episode { row.append(.trailer) }
        row.append(.watched)
        if supportsDownloads { row.append(.download) }
        if supportsLists, [.movie, .series, .episode].contains(itemType) { row.append(.addToList) }
        row.append(.more)
        return row
    }
}

/// The navigation and admin entries at the top of a detail page's More menu
/// (#760): Go to Series and Go to Season for an episode, then Add to Channel
/// for the server's administrators.
enum DetailMenuEntry: Equatable {
    case goToSeries(seriesId: String)
    case goToSeason(seasonId: String, number: Int?)
    case addToChannel(ChannelTarget)

    var title: String {
        switch self {
        case .goToSeries: return "Go to Series"
        case .goToSeason(_, let number): return number.map { "Go to Season \($0)" } ?? "Go to Season"
        case .addToChannel: return "Add to Channel"
        }
    }

    var systemImage: String {
        switch self {
        case .goToSeries: return "tv"
        case .goToSeason: return "rectangle.stack"
        case .addToChannel: return "rectangle.stack.badge.plus"
        }
    }

    static func entries(for item: BaseItemDto, canManageChannels: Bool) -> [DetailMenuEntry] {
        var entries: [DetailMenuEntry] = []
        if item.type == .episode {
            if let seriesId = item.seriesId { entries.append(.goToSeries(seriesId: seriesId)) }
            if let seasonId = item.seasonId {
                entries.append(.goToSeason(seasonId: seasonId, number: item.parentIndexNumber))
            }
        }
        if canManageChannels, let target = ChannelTarget(item: item) {
            entries.append(.addToChannel(target))
        }
        return entries
    }
}
