import Foundation

extension Notification.Name {
    /// Posted on the main actor after the server accepted a watched/unwatched
    /// mark. `object` is a `PlayedStateChange`.
    static let sashimiPlayedStateDidChange = Notification.Name("sashimiPlayedStateDidChange")
}

/// A watched/unwatched mark the server has accepted (#750). Detail screens
/// listen for it so the checkmarks on their episode lists follow a mark made
/// anywhere else: the episode page shown over them, a context menu, a season
/// or series mark.
struct PlayedStateChange: Equatable, Sendable {
    /// The item that was marked: an episode, movie, season or series.
    let itemId: String
    let played: Bool

    /// Whether a screen showing `episodes` (and, for a series or season page,
    /// belonging to `containerIds`) must refresh them. A season or series
    /// mark changes every episode under it, so it matches by container.
    func affects(episodes: [BaseItemDto], containerIds: [String?]) -> Bool {
        if episodes.contains(where: { $0.id == itemId }) { return true }
        if containerIds.contains(where: { $0 == itemId }) { return true }
        return episodes.contains { $0.seasonId == itemId || $0.seriesId == itemId }
    }

    @MainActor
    func post() {
        NotificationCenter.default.post(name: .sashimiPlayedStateDidChange, object: self)
    }

    static func from(_ notification: Notification) -> PlayedStateChange? {
        notification.object as? PlayedStateChange
    }

    /// The season on screen fetched again, when this change touches it; nil
    /// when nothing needs refreshing or the fetch fails (keep what is shown).
    func refreshedEpisodes(
        showing episodes: [BaseItemDto],
        containerIds: [String?],
        seriesId: String?,
        seasonId: String?,
        client: JellyfinClient = .shared
    ) async -> [BaseItemDto]? {
        guard let seriesId, let seasonId, !seasonId.hasPrefix("offline-season-"),
              affects(episodes: episodes, containerIds: containerIds + [seasonId]) else { return nil }
        return try? await client.getEpisodes(seriesId: seriesId, seasonId: seasonId)
    }
}
