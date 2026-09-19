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
        guard let item = items[entry.itemId] else { return "—" }
        if item.type == .episode { return item.seriesName ?? item.name ?? "—" }
        return item.name ?? "—"
    }

    func subtitle(for entry: GuideEntry) -> String? {
        guard let item = items[entry.itemId] else { return nil }
        if item.type == .episode, let season = item.parentIndexNumber, let episode = item.indexNumber {
            return "S\(season)E\(episode)"
        }
        if let year = item.productionYear { return String(year) }
        return nil
    }
}

@MainActor
final class GuideViewModel: ObservableObject {
    @Published private(set) var rows: [GuideRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    /// The window the guide covers. Three hours reads on one screen without
    /// horizontal scrolling, which matters on a remote.
    let hours: Double = 3

    private let client: JellyfinClient

    init(client: JellyfinClient? = nil) {
        self.client = client ?? JellyfinClient.shared
    }

    func load() async {
        isLoading = rows.isEmpty
        loadFailed = false
        defer { isLoading = false }

        do {
            let guides = try await client.getChannelGuide(hours: hours)

            // Fetch each distinct item once. The same episode airs repeatedly
            // across a window, and six channels of 22-minute programmes would
            // otherwise be dozens of duplicate requests.
            let ids = Set(guides.flatMap { $0.programs.map(\.itemId) })
            var items: [String: BaseItemDto] = [:]
            for id in ids {
                if let item = try? await client.getItem(itemId: id) { items[id] = item }
            }

            rows = guides.map { GuideRow(channel: $0, items: items) }
        } catch {
            // An unreachable server is not the same as a server with no
            // channels; the client returns [] for the latter.
            loadFailed = true
            rows = []
        }
    }

    /// Resolve a tune-in for a programme that is airing now.
    func tuneIn(to channelID: String) async -> (itemID: String, context: ChannelPlaybackContext)? {
        do {
            guard let now = try await client.getChannelNowPlaying(channelId: channelID) else { return nil }
            return (
                now.itemId,
                ChannelPlaybackContext(
                    channelID: channelID,
                    startPositionSeconds: now.startPositionSeconds,
                    endsAt: now.endUtc,
                    nextItemID: now.nextItemId
                )
            )
        } catch {
            return nil
        }
    }
}
