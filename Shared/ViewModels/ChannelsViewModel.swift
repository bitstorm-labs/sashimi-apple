import Foundation

/// Loads the channel list and resolves a tune-in.
@MainActor
final class ChannelsViewModel: ObservableObject {
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
        } catch {
            // An unreachable server is different from a server with no plugin:
            // the client returns [] for the latter, so an error here is real and
            // should not be shown as "you have no channels".
            loadFailed = true
            channels = []
        }
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
