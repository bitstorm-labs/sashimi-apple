import Foundation

/// A resolved channel tune-in, ready to present.
///
/// `fullScreenCover(item:)` needs an Identifiable payload, and the identity has
/// to change per tune so that tuning to a different channel — or the same one
/// after it has rolled to the next programme — presents a fresh player rather
/// than reusing the old one.
struct TunedChannel: Identifiable, Equatable {
    let item: BaseItemDto
    let context: ChannelPlaybackContext

    var id: String { "\(context.channelID)-\(item.id)-\(context.startPositionSeconds)" }
}
