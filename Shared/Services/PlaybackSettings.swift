import SwiftUI

@MainActor
class PlaybackSettings: ObservableObject {
    static let shared = PlaybackSettings()

    // 0 = Auto (no cap). Must stay the default: before this setting was wired
    // into playback it was cosmetic, so a nonzero default would silently cap
    // users who never opened Video Quality settings.
    @AppStorage("maxBitrate") var maxBitrate = 0
    @AppStorage("autoPlayNextEpisode") var autoPlayNextEpisode = true
    @AppStorage("autoSkipIntro") var autoSkipIntro = false
    @AppStorage("autoSkipCredits") var autoSkipCredits = false
    @AppStorage("resumeThresholdSeconds") var resumeThresholdSeconds = 30
    @AppStorage("preferredAudioLanguage") var preferredAudioLanguage = ""
    @AppStorage("preferredSubtitleLanguage") var preferredSubtitleLanguage = ""
    @AppStorage("subtitlesEnabled") var subtitlesEnabled = false
    @AppStorage("forceDirectPlay") var forceDirectPlay = false
    @AppStorage("use24HourTime") var use24HourTime = false
    @AppStorage("showQualityBadges") var showQualityBadges = true
    @AppStorage("showReviewRatings") var showReviewRatings = true
    // When false (default) the cover review-rating badge shows a TV show's
    // overall rating rather than an individual episode's. Since episode DTOs
    // don't carry the series' overall rating, episode cards suppress the badge
    // unless the user opts into per-episode ratings here.
    @AppStorage("useEpisodeRatings") var useEpisodeRatings = false
    // Phase-1 debug flag with NO settings UI (set via `defaults write` /
    // simctl): sends the VLC-shaped device profile so the server's response
    // to it can be observed in the pbinfo.response diagnostics, while the
    // player itself is still AVPlayer. With this on, an MKV negotiates as
    // direct play and AVPlayer then can't render it — that's expected; this
    // exists to verify the negotiation, not to play video. Replaced by the
    // real engine setting when the VLC engine lands.
    @AppStorage("debugVLCDeviceProfile") var debugVLCDeviceProfile = false
}
