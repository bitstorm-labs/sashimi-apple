import Foundation

/// A tune-in to a virtual channel.
///
/// Carried instead of the ordinary resume path because the two mean opposite
/// things: a resume position is where *this viewer* stopped, while a channel
/// offset is how far into the programme the broadcast already is. Restoring a
/// resume position on a channel would put the viewer somewhere the channel is
/// not.
struct ChannelPlaybackContext: Equatable {
    let channelID: String

    /// How far into the item the channel is already, in seconds.
    let startPositionSeconds: Double

    /// When this programme ends and the next begins.
    let endsAt: Date

    /// The following programme, so it can be prepared before the boundary.
    let nextItemID: String?

    /// Tuned during a break: the programme starts then, from its beginning,
    /// and the player shows "up next" until it does.
    var breakUntil: Date?

    init(channelID: String, startPositionSeconds: Double, endsAt: Date, nextItemID: String?, breakUntil: Date? = nil) {
        self.channelID = channelID
        self.startPositionSeconds = startPositionSeconds
        self.endsAt = endsAt
        self.nextItemID = nextItemID
        self.breakUntil = breakUntil
    }

    /// The context for joining a channel from its now-playing answer.
    init(channelID: String, now: ChannelNowPlaying) {
        self.init(
            channelID: channelID,
            startPositionSeconds: now.isBreak ? 0 : now.startPositionSeconds,
            endsAt: now.endUtc,
            nextItemID: now.nextItemId,
            breakUntil: now.isBreak ? now.startUtc : nil
        )
    }

    var startPositionTicks: Int64 {
        Int64(startPositionSeconds * 10_000_000)
    }
}

/// Swallows every playback report.
///
/// Channel viewing must not touch watch state: a channel runs whether or not
/// anyone is tuned in, so reporting progress against it would write positions
/// nobody asked for onto items across every client and device — and marking a
/// programme watched because it happened to air is worse still.
///
/// This is a null conformance rather than a flag checked at each call site, and
/// that is the point. `PlayerPlaybackReporting` has six methods and more will be
/// added; a conditional guard has to be remembered at every one of them, and the
/// failure mode of forgetting is silent corruption of the user's library. With
/// nothing to remember, there is nothing to forget.
@MainActor
final class ChannelPlaybackReporter: PlayerPlaybackReporting {
    func reset() {}

    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}

    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}

    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}

    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {}

    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
}
