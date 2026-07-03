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
}
