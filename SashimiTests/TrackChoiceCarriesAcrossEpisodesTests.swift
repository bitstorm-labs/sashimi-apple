import XCTest
@testable import Sashimi

/// #818: #774 remembered the picks per item, so leaving the player and
/// starting another episode of the same series (from the season page, or the
/// next one) came back with subtitles off. "I had them on, exited the show to
/// check the season of MobLand, clicked play again and had to turn subtitles
/// on."
///
/// Driven through API that existed before the fix (`sessionSubtitlePreference`,
/// `beginStop`, `setCurrentItem`), so the file compiles against the old code
/// and each test fails there on its assertion.
@MainActor
final class TrackChoiceCarriesAcrossEpisodesTests: XCTestCase {
    private var seriesID = ""

    override func setUp() {
        super.setUp()
        // Fresh ids per test: the memory is the app's real store.
        seriesID = "series-\(UUID().uuidString)"
    }

    private let sdh = PlayerViewModel.SubtitlePreference(language: "eng", displayTitle: "English SDH", isExternal: false)
    private let french = PlayerViewModel.SubtitlePreference(language: "fra", displayTitle: "French", isExternal: false)

    func testASubtitlePickCarriesToAnotherEpisodeOfTheSeries() async {
        await watch(episode(1), subtitle: sdh, audio: .init(language: "jpn", displayName: "Japanese"))

        let next = open(episode(2))

        XCTAssertEqual(next.sessionSubtitlePreference, sdh)
        XCTAssertEqual(next.sessionAudioPreference?.displayName, "Japanese")
    }

    func testAnotherSeriesDoesNotInheritThePick() async {
        await watch(episode(1), subtitle: sdh)

        let other = open(episode(1, series: "other-\(UUID().uuidString)"))

        XCTAssertNil(other.sessionSubtitlePreference)
    }

    func testTheLatestPickInTheSeriesWins() async {
        await watch(episode(1), subtitle: sdh)
        await watch(episode(2), subtitle: french)

        XCTAssertEqual(open(episode(1)).sessionSubtitlePreference, french, "going back an episode keeps today's choice")
        XCTAssertEqual(open(episode(3)).sessionSubtitlePreference, french)
    }

    func testTurningSubtitlesOffCarriesToo() async {
        await watch(episode(1), subtitle: sdh)
        await watch(episode(2), subtitle: nil)

        XCTAssertNil(open(episode(3)).sessionSubtitlePreference)
        XCTAssertNil(open(episode(1)).sessionSubtitlePreference)
    }

    /// Restoring is for opening the player. Inside one session the player's
    /// own state carries across episodes, so subtitles turned off here must
    /// not be switched back on by the next episode's remembered pick.
    func testTurningSubtitlesOffMidSessionSurvivesTheNextEpisode() async {
        await watch(episode(1), subtitle: sdh)

        let player = open(episode(2))
        XCTAssertEqual(player.sessionSubtitlePreference, sdh)
        player.sessionSubtitlePreference = nil
        player.setCurrentItem(episode(3))

        XCTAssertNil(player.sessionSubtitlePreference)
    }

    func testAMovieStillOnlyRemembersItself() async {
        await watch(movie("m1"), subtitle: sdh)

        XCTAssertEqual(open(movie("m1")).sessionSubtitlePreference, sdh)
        XCTAssertNil(open(movie("m2")).sessionSubtitlePreference)
    }

    // MARK: - Helpers

    private func watch(
        _ item: BaseItemDto,
        subtitle: PlayerViewModel.SubtitlePreference?,
        audio: PlayerViewModel.AudioPreference? = nil
    ) async {
        let viewModel = open(item)
        viewModel.sessionSubtitlePreference = subtitle
        viewModel.sessionAudioPreference = audio
        await viewModel.beginStop(reason: .userStop).value
    }

    private func open(_ item: BaseItemDto) -> PlayerViewModel {
        let viewModel = PlayerViewModel(client: JellyfinClient(), reporter: SilentReporter())
        viewModel.setCurrentItem(item)
        return viewModel
    }

    private func episode(_ number: Int, series: String? = nil) -> BaseItemDto {
        let series = series ?? seriesID
        return item(id: "\(series)-e\(number)", type: .episode, seriesId: series, index: number)
    }

    private func movie(_ id: String) -> BaseItemDto {
        item(id: "\(seriesID)-\(id)", type: .movie, seriesId: nil, index: nil)
    }

    private func item(id: String, type: ItemType, seriesId: String?, index: Int?) -> BaseItemDto {
        BaseItemDto(
            id: id, name: "Item", type: type, seriesName: seriesId == nil ? nil : "MobLand", seriesId: seriesId,
            seasonId: nil, parentId: nil, indexNumber: index, parentIndexNumber: index == nil ? nil : 2, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil, backdropImageTags: nil,
            parentBackdropImageTags: nil, primaryImageAspectRatio: nil, mediaType: nil,
            libraryName: "Shows", productionYear: 2025, communityRating: nil, officialRating: nil,
            genres: nil, taglines: nil, people: nil, criticRating: nil, premiereDate: nil, chapters: nil,
            path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
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
