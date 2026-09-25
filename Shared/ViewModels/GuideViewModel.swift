import Foundation

/// One channel's row in the guide, with the item metadata its blocks need.
struct GuideRow: Identifiable, Equatable {
    let channel: ChannelGuide
    /// Item detail keyed by id, so a block can show a title without each one
    /// fetching separately — airings repeat, and a 3-hour guide across six
    /// channels asks for the same handful of items many times over.
    let items: [String: BaseItemDto]

    var id: String { channel.id }

    func title(for entry: GuideEntry) -> String {
        // The server's own words first; the fetched item only for a guide
        // from a plugin that predates them.
        if let name = entry.name, !name.isEmpty {
            if entry.type == "Episode", let series = entry.seriesName, !series.isEmpty { return series }
            return name
        }
        guard let item = items[entry.itemId] else { return "—" }
        if item.type == .episode { return item.seriesName ?? item.name }
        return item.name
    }

    func subtitle(for entry: GuideEntry) -> String? {
        if let name = entry.name, !name.isEmpty {
            if entry.type == "Episode", let season = entry.seasonNumber, let episode = entry.episodeNumber {
                return Self.episodeLabel(season: season, episode: episode, title: name)
            }
            if let year = entry.productionYear { return String(year) }
            return nil
        }
        guard let item = items[entry.itemId] else { return nil }
        if item.type == .episode, let season = item.parentIndexNumber, let episode = item.indexNumber {
            return Self.episodeLabel(season: season, episode: episode, title: item.name)
        }
        if let year = item.productionYear { return String(year) }
        return nil
    }

    /// A YouTube channel's "episodes" carry the upload year as the season and
    /// a five-or-six-digit index as the episode, so "S2025E123199" says
    /// nothing. The video's own title is what the card should say beneath
    /// the channel's name.
    static func episodeLabel(season: Int, episode: Int, title: String) -> String {
        if BaseItemDto.isDatedEpisode(season: season, episode: episode), !title.isEmpty { return title }
        return "S\(season)E\(episode)"
    }
}

/// The three calls the guide makes. A protocol rather than the concrete client
/// so the model's rules — what a failed refresh does to rows already shown,
/// which programmes need an item fetch — can be tested without a server, the
/// same seam the filmography and episode navigation models use.
protocol GuideClient: Sendable {
    func getChannelGuide(hours: Double) async throws -> [ChannelGuide]
    func getItem(itemId: String) async throws -> BaseItemDto
    func getChannelNowPlaying(channelId: String) async throws -> ChannelNowPlaying?
}

extension JellyfinClient: GuideClient {}

@MainActor
final class GuideViewModel: ObservableObject {
    @Published private(set) var rows: [GuideRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    /// The window the guide covers. Three hours is what the iPad's grid can
    /// show; the tvOS strip pages per row and asks for a week.
    let hours: Double

    private let client: GuideClient

    init(client: GuideClient? = nil, hours: Double = 3) {
        self.client = client ?? JellyfinClient.shared
        self.hours = hours
    }

    func load() async {
        isLoading = rows.isEmpty
        loadFailed = false
        defer { isLoading = false }

        do {
            let guides = try await client.getChannelGuide(hours: hours)

            // Only items the server did not describe are fetched — one request
            // each, once per distinct item. A week of guide from a plugin that
            // names its programmes needs none; from an older one this is the
            // old behaviour.
            let ids = Set(guides.flatMap { $0.programs.filter { $0.name == nil }.map(\.itemId) })
            var items: [String: BaseItemDto] = [:]
            for id in ids {
                if let item = try? await client.getItem(itemId: id) { items[id] = item }
            }

            rows = guides.map { GuideRow(channel: $0, items: items) }
        } catch {
            // An unreachable server is not the same as a server with no
            // channels; the client returns [] for the latter. And a failed
            // *refresh* is not the same as a failed first load: the guide
            // reloads itself every minute, and one dropped request must not
            // wipe a grid the viewer is looking at — the rows already shown
            // stay until a load succeeds or they are cleared on purpose.
            loadFailed = true
        }
    }

    /// Resolve a tune-in for a programme that is airing now.
    func tuneIn(to channelID: String) async -> (itemID: String, context: ChannelPlaybackContext)? {
        do {
            guard let now = try await client.getChannelNowPlaying(channelId: channelID) else { return nil }
            return (
                now.itemId,
                ChannelPlaybackContext(channelID: channelID, now: now)
            )
        } catch {
            return nil
        }
    }
}
