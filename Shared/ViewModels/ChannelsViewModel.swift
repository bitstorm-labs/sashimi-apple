import Foundation

/// Loads the channel list and resolves a tune-in.
/// A channel plus what it is airing, which is what the card actually shows.
struct ChannelCard: Identifiable, Equatable {
    let channel: VirtualChannel
    let nowPlaying: ChannelNowPlaying?
    let item: BaseItemDto?

    var id: String { channel.id }
    var isOffAir: Bool { nowPlaying == nil }

    /// How far through the current programme a viewer would be joining.
    var progress: Double {
        guard let now = nowPlaying else { return 0 }
        let total = now.endUtc.timeIntervalSince(now.startUtc)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.startPositionSeconds / total))
    }

    var minutesRemaining: Int {
        guard let now = nowPlaying else { return 0 }
        return max(0, Int(now.endUtc.timeIntervalSinceNow / 60))
    }
}

@MainActor
final class ChannelsViewModel: ObservableObject {
    /// Channels with their current programme resolved, for display.
    @Published private(set) var cards: [ChannelCard] = []

    @Published private(set) var channels: [VirtualChannel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    /// Off-air channels stay in the list; a channel that is off air now will be
    /// back on later, and hiding it would make the list flicker in and out
    /// across the day.
    @Published private(set) var offAirChannelIDs: Set<String> = []

    private let client: JellyfinClient

    init(client: JellyfinClient? = nil) {
        self.client = client ?? JellyfinClient.shared
    }

    func load() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        do {
            channels = try await client.getVirtualChannels()
            await loadCards()
        } catch {
            // An unreachable server is different from a server with no plugin:
            // the client returns [] for the latter, so an error here is real and
            // should not be shown as "you have no channels".
            loadFailed = true
            channels = []
            cards = []
        }
    }

    /// Resolve what each channel is airing so the row can show it.
    ///
    /// Done per channel rather than in one call because a channel that is off
    /// air, or whose current item has since been deleted, must not stop the rest
    /// of the row from rendering.
    private func loadCards() async {
        var built: [ChannelCard] = []
        for channel in channels {
            let now = try? await client.getChannelNowPlaying(channelId: channel.id)
            if now == nil { offAirChannelIDs.insert(channel.id) } else { offAirChannelIDs.remove(channel.id) }
            var item: BaseItemDto?
            if let now { item = try? await client.getItem(itemId: now.itemId) }
            built.append(ChannelCard(channel: channel, nowPlaying: now, item: item))
        }
        cards = built
    }

    /// Resolve what to play for a channel.
    ///
    /// Returns the item to open and the context that makes playback ephemeral,
    /// or `nil` when the channel is off air.
    func tuneIn(to channel: VirtualChannel) async -> (itemID: String, context: ChannelPlaybackContext)? {
        do {
            guard let now = try await client.getChannelNowPlaying(channelId: channel.id) else {
                offAirChannelIDs.insert(channel.id)
                return nil
            }

            offAirChannelIDs.remove(channel.id)
            return (
                now.itemId,
                ChannelPlaybackContext(
                    channelID: channel.id,
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
