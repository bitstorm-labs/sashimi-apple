import Foundation

/// The season page (#760): one season of a show, its episodes with their
/// watched state, Play for the next unwatched episode and the season-wide
/// watched mark. Shared by the tvOS and iOS season pages.
@MainActor
final class SeasonDetailViewModel: ObservableObject {
    @Published private(set) var season: BaseItemDto
    @Published private(set) var series: BaseItemDto?
    @Published var episodes: [BaseItemDto] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadFailed = false

    private let client: JellyfinClient

    init(season: BaseItemDto, client: JellyfinClient = .shared) {
        self.season = season
        self.client = client
    }

    var seriesId: String? { season.seriesId ?? season.parentId }

    /// The show's name: the page's title.
    var title: String { season.seriesName ?? series?.name ?? season.name }

    var subtitle: String { SeasonPageText.subtitle(seasonName: season.name, episodes: episodes) }

    var playTarget: SeasonPlayTarget? { SeasonPlayTarget.choose(from: episodes) }

    /// Mark Season Watched, or Unwatched once every episode is watched.
    var watchAction: SeasonWatchAction {
        SeasonWatchAction.resolve(season: season, loadedEpisodes: hasLoaded ? episodes : nil)
    }

    var status: SeriesStatus? { SeriesStatus(item: season, seriesStatus: series?.status) }

    /// The season's own rating is rarely set; the show's is.
    var officialRating: String? { season.officialRating ?? series?.officialRating }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        if let fresh = try? await client.getItem(itemId: season.id) {
            season = fresh
        }
        if series == nil, let seriesId {
            series = try? await client.getItem(itemId: seriesId)
        }
        guard let seriesId else {
            loadFailed = true
            return
        }
        do {
            episodes = try await client.getEpisodes(seriesId: seriesId, seasonId: season.id)
            loadFailed = false
        } catch {
            loadFailed = !hasLoaded
        }
        hasLoaded = true
    }

    /// Apply a confirmed season-wide mark, then show the result. Returns
    /// false when the server refused it.
    func applySeasonWatch(_ action: SeasonWatchAction) async -> Bool {
        do {
            try await action.apply(seasonId: season.id, using: client)
        } catch {
            return false
        }
        await load()
        return true
    }

    /// A watched mark made anywhere (the episode page over this one, a
    /// context menu, a series mark) shows on this page's checkmarks.
    func apply(_ change: PlayedStateChange) async {
        guard let seriesId, let fresh = await change.refreshedEpisodes(
            showing: episodes,
            containerIds: [season.id, seriesId],
            seriesId: seriesId,
            seasonId: season.id,
            client: client
        ) else { return }
        episodes = fresh
    }
}
