import Foundation

/// What the season page's Play button plays (#760): the next unwatched
/// episode of the season, resumed when it has progress. Once every episode is
/// watched it plays E1 again from the start.
struct SeasonPlayTarget: Equatable {
    let episode: BaseItemDto
    /// The episode has a saved position to resume from.
    let isResume: Bool
    /// The whole season is watched: play E1 from the top, not its old position.
    let startsOver: Bool

    /// `episodes` are the season's episodes in order. "Next" is the first
    /// unwatched episode after the last watched one, so a skipped early
    /// episode doesn't pull Play back to the start of the season; when the
    /// last episode is watched, it falls back to the first unwatched one.
    static func choose(from episodes: [BaseItemDto]) -> SeasonPlayTarget? {
        guard let first = episodes.first else { return nil }
        let isPlayed: (BaseItemDto) -> Bool = { $0.userData?.played == true }
        let afterLastWatched = episodes.lastIndex(where: isPlayed).map { episodes[($0 + 1)...] } ?? episodes[...]
        guard let next = afterLastWatched.first(where: { !isPlayed($0) }) ?? episodes.first(where: { !isPlayed($0) }) else {
            return SeasonPlayTarget(episode: first, isResume: false, startsOver: true)
        }
        let hasPosition = (next.userData?.playbackPositionTicks ?? 0) > 0
        return SeasonPlayTarget(episode: next, isResume: hasPosition, startsOver: false)
    }

    /// "Play S2·E6" / "Resume S2·E6"; just the verb without episode numbers.
    var title: String {
        let verb = isResume ? "Resume" : "Play"
        guard let season = episode.parentIndexNumber, let number = episode.indexNumber else { return verb }
        return "\(verb) S\(season)\u{00B7}E\(number)"
    }
}

/// Text on the season page's header.
enum SeasonPageText {
    /// "Season 2 · 8 episodes · 5 of 8 watched".
    static func subtitle(seasonName: String, episodes: [BaseItemDto]) -> String {
        let count = episodes.count
        let watched = episodes.filter { $0.userData?.played == true }.count
        let episodesText = count == 1 ? "1 episode" : "\(count) episodes"
        return [seasonName, episodesText, "\(watched) of \(count) watched"].joined(separator: " \u{00B7} ")
    }

    /// Offline seasons built from downloads have no server item to show.
    static func canOpen(_ season: BaseItemDto, isConnected: Bool) -> Bool {
        isConnected && !season.id.hasPrefix("offline-season-")
    }
}
