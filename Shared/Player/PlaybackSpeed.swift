import AVFoundation

/// The one way both players change playback speed.
///
/// `AVPlayer.play()` resumes at `defaultRate`, not at the last `rate`. The tvOS
/// speed menu used to set only `rate`, so any pause (or a seek that paused)
/// silently dropped the viewer back to 1x while the menu still showed 1.5x.
/// Setting `defaultRate` makes the choice stick; `rate` is only touched while
/// playing so picking a speed never un-pauses the video.
enum PlaybackSpeed {
    static func apply(_ speed: Float, to player: AVPlayer) {
        player.defaultRate = speed
        if player.rate != 0 {
            player.rate = speed
        }
    }

    /// The speed the viewer chose, whether or not the player is paused.
    static func current(of player: AVPlayer) -> Float {
        player.defaultRate > 0 ? player.defaultRate : 1.0
    }
}
