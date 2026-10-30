import XCTest
@testable import Sashimi

/// #818, downloaded episodes: the subtitle choice was only ever applied to a
/// streamed item (`currentMediaSource`), so a downloaded episode always
/// started with subtitles off — whatever was picked a moment earlier, and
/// whatever Settings said.
///
/// Driven through API that existed before the fix (`isOfflinePlayback`,
/// `offlineSubtitles`, `sessionSubtitlePreference`,
/// `applySessionSubtitlePreference`, `applyPreferredSubtitles`), so the file
/// compiles against the old code and each test fails there on its assertion.
@MainActor
final class OfflineSubtitleChoiceTests: XCTestCase {
    private let settings = PlaybackSettings.shared
    private var savedEnabled = false
    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedEnabled = settings.subtitlesEnabled
        savedLanguage = settings.preferredSubtitleLanguage
    }

    override func tearDown() {
        settings.subtitlesEnabled = savedEnabled
        settings.preferredSubtitleLanguage = savedLanguage
        super.tearDown()
    }

    func testTheSessionPickSelectsTheMatchingDownloadedTrack() {
        let player = offlinePlayer()
        player.sessionSubtitlePreference = .init(language: "eng", displayTitle: "English SDH", isExternal: false)

        XCTAssertTrue(player.applySessionSubtitlePreference())
        XCTAssertEqual(player.selectedSubtitleTrackId, "4", "the SDH file, not the first English one")
    }

    func testTheSettingsLanguageSelectsADownloadedTrack() {
        settings.subtitlesEnabled = true
        settings.preferredSubtitleLanguage = "spa"
        let player = offlinePlayer()

        player.applyPreferredSubtitles()

        XCTAssertEqual(player.selectedSubtitleTrackId, "5")
    }

    func testSubtitlesOffInSettingsStaysOff() {
        settings.subtitlesEnabled = false
        settings.preferredSubtitleLanguage = "eng"
        let player = offlinePlayer()

        player.applyPreferredSubtitles()

        XCTAssertNotEqual(player.selectedSubtitleTrackId, "3")
        XCTAssertNotEqual(player.selectedSubtitleTrackId, "4")
    }

    // MARK: - Helpers

    private func offlinePlayer() -> PlayerViewModel {
        let viewModel = PlayerViewModel(client: JellyfinClient(), reporter: SilentReporter())
        viewModel.isOfflinePlayback = true
        let folder = FileManager.default.temporaryDirectory
        viewModel.offlineSubtitles = [
            OfflineSubtitle(index: 3, language: "eng", displayTitle: "English", fileURL: folder.appendingPathComponent("3_eng.vtt")),
            OfflineSubtitle(index: 4, language: "eng", displayTitle: "English SDH", fileURL: folder.appendingPathComponent("4_eng.vtt")),
            OfflineSubtitle(index: 5, language: "spa", displayTitle: "Spanish", fileURL: folder.appendingPathComponent("5_spa.vtt"))
        ]
        return viewModel
    }
}

/// Accepts every report and does nothing: these tests are about tracks.
private final class SilentReporter: PlayerPlaybackReporting {
    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
}
