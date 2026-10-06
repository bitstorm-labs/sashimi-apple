import XCTest
@testable import Sashimi

/// The end of a YouTube (Pinchflat) video, replayed on a real channel's data.
///
/// The fixture is the "Simon d'Entremont" channel as the server returned it
/// on 2026-10-06 to the player's own navigation queries (`/Users/{id}/Items`,
/// `SortBy=IndexNumber`, `Limit=100`): one season per upload year and an
/// `MMDD99` episode number, so `S2026:E100599` is the 2026-10-05 upload and
/// the newest one. Titles are left out; ids are the Pinchflat file stems.
///
/// iPad and iPhone used to close the player after the newest video: there is
/// nothing after it, and the "no more episodes" screen was shown only when
/// the per-device "Show Episode Navigation Controls" setting was on — the
/// Apple TV had it on, the iPad did not (issue #619).
@MainActor
final class YouTubeUpNextTests: XCTestCase {
    private var savedAutoPlay = true
    private var savedControls = false

    override func setUp() async throws {
        savedAutoPlay = PlaybackSettings.shared.autoPlayNextEpisode
        savedControls = PlaybackSettings.shared.showEpisodeNavigationControls
        PlaybackSettings.shared.autoPlayNextEpisode = true
        // The default, and what the iPad in the report had.
        PlaybackSettings.shared.showEpisodeNavigationControls = PlaybackSettings.defaultShowEpisodeNavigationControls
    }

    override func tearDown() async throws {
        PlaybackSettings.shared.autoPlayNextEpisode = savedAutoPlay
        PlaybackSettings.shared.showEpisodeNavigationControls = savedControls
    }

    // MARK: - The newest video

    func testNewestVideoShowsTheCaughtUpScreenInsteadOfClosingThePlayer() async {
        let (viewModel, loader) = await finish(Channel.episode(2026, 100_599))

        XCTAssertTrue(viewModel.playbackEnded)
        XCTAssertNotNil(viewModel.episodeUpNext, "The player view dismisses when this is nil: the video 'just stops'")
        XCTAssertEqual(viewModel.transitionState.endCard, .finalEpisode)
        XCTAssertEqual(viewModel.episodeUpNext?.showsCountdown, false)
        XCTAssertTrue(loader.loadedItemIDs.isEmpty, "Nothing newer to start")
        await viewModel.stop()
    }

    func testCaughtUpScreenSpeaksOfTheChannelNotASeries() async {
        let (viewModel, _) = await finish(Channel.episode(2026, 100_599))
        let upNext = viewModel.episodeUpNext

        XCTAssertEqual(upNext?.eyebrow, "ALL CAUGHT UP")
        XCTAssertEqual(upNext?.title, "You're all caught up")
        XCTAssertEqual(upNext?.message, "You've watched the latest from Simon d'Entremont.")
        XCTAssertNil(upNext?.episodeLabel, "S2026:E100599 means nothing to a viewer")
        await viewModel.stop()
    }

    func testNewestVideoShowsTheSameScreenWithNavigationControlsOn() async {
        PlaybackSettings.shared.showEpisodeNavigationControls = true
        let (viewModel, _) = await finish(Channel.episode(2026, 100_599))

        XCTAssertEqual(viewModel.transitionState.endCard, .finalEpisode)
        XCTAssertEqual(viewModel.episodeUpNext?.title, "You're all caught up")
        await viewModel.stop()
    }

    // MARK: - A newer video exists

    func testOlderVideoOffersTheNextUploadWithACountdown() async {
        let (viewModel, loader) = await finish(Channel.episode(2026, 92_599))

        XCTAssertEqual(viewModel.transitionState.endCard, .nextEpisode)
        XCTAssertEqual(viewModel.episodeUpNext?.episode?.id, "s2026e100599", "92599 → 100599: numeric, not lexical")
        XCTAssertEqual(viewModel.episodeUpNext?.isCountingDown, true)
        XCTAssertNil(viewModel.episodeUpNext?.episodeLabel)
        XCTAssertEqual(viewModel.episodeUpNext?.showsSkip, false, "Nothing after the newest video")

        await viewModel.playNextEpisode()
        XCTAssertEqual(loader.loadedItemIDs, ["s2026e100599"])
        await viewModel.stop()
    }

    func testLastUploadOfAYearRollsOverToTheFirstOfTheNext() async {
        let (viewModel, _) = await finish(Channel.episode(2025, 122_399))

        XCTAssertEqual(viewModel.episodeUpNext?.episode?.id, "s2026e10699")
        XCTAssertEqual(viewModel.episodeUpNext?.isCountingDown, true)
        await viewModel.stop()
    }

    // MARK: - Lookup failure

    func testFailedLookupShowsItsScreenWithNavigationControlsOff() async {
        let viewModel = PlayerViewModel(
            navigationClient: FailingNavigationClient(),
            reporter: SilentReporter(),
            transitionLoader: RecordingLoader()
        )
        viewModel.currentItem = Channel.episode(2026, 92_599)
        viewModel.upNextSleep = { _ in try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        XCTAssertEqual(viewModel.transitionState.endCard, .lookupFailed)
        XCTAssertNotNil(viewModel.episodeUpNext)
        await viewModel.stop()
    }

    // MARK: - Not episodes

    /// Movies and standalone videos never had an end screen and still close.
    func testMoviesAndStandaloneVideosStillCloseThePlayer() async {
        PlaybackSettings.shared.autoPlayNextEpisode = false
        PlaybackSettings.shared.showEpisodeNavigationControls = true
        for type in [ItemType.movie, .video] {
            let viewModel = PlayerViewModel(
                navigationClient: Channel.client(),
                reporter: SilentReporter(),
                transitionLoader: RecordingLoader()
            )
            viewModel.currentItem = Channel.episode(2026, 100_599, type: type)

            await viewModel.refreshEpisodeNavigation()
            await viewModel.handlePlaybackEnded()

            XCTAssertTrue(viewModel.playbackEnded, "\(type)")
            XCTAssertNil(viewModel.episodeUpNext, "\(type)")
            XCTAssertNil(viewModel.transitionState.endCard, "\(type)")
        }
    }

    // MARK: - Harness

    private func finish(_ item: BaseItemDto) async -> (PlayerViewModel, RecordingLoader) {
        let loader = RecordingLoader()
        let viewModel = PlayerViewModel(
            navigationClient: Channel.client(),
            reporter: SilentReporter(),
            transitionLoader: loader
        )
        viewModel.currentItem = item
        // The countdown is driven by hand; the real wait never ends.
        viewModel.upNextSleep = { _ in try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()
        await viewModel.upNextLookupTask?.value
        return (viewModel, loader)
    }
}

// MARK: - Fixture

private enum Channel {
    static let name = "Simon d'Entremont"
    static let seriesID = "ccecdc6a1f85317e575376fa9b120438"
    static let seasonIDs = [
        2025: "d4198a9feb3b17e369031a9520d65ff2",
        2026: "ed7e9a2987492cc61747460cb24a89fa"
    ]

    /// `IndexNumber`s per season, in the order the server returned them.
    static let uploads: [Int: [Int]] = [
        2025: [
            71_599, 72_499, 73_099, 80_699, 81_399, 82_199, 90_199, 90_999, 91_799, 92_699,
            100_699, 101_599, 110_199, 110_699, 111_399, 112_499, 112_999, 121_099, 121_699, 122_399
        ],
        2026: [
            10_699, 11_399, 12_199, 20_299, 20_899, 21_599, 22_099, 22_899, 30_699, 31_999,
            32_299, 32_999, 40_799, 41_599, 42_199, 42_899, 50_599, 51_299, 51_999, 52_499,
            53_199, 60_799, 61_499, 61_999, 62_799, 70_799, 71_399, 72_199, 72_899, 80_599,
            81_299, 82_199, 82_899, 90_499, 90_999, 91_899, 92_599, 100_599
        ]
    ]

    static func client() -> FixtureNavigationClient {
        var itemsByParent: [String: [BaseItemDto]] = [:]
        itemsByParent[seriesID] = [season(2025), season(2026)]
        for (year, numbers) in uploads {
            itemsByParent[seasonIDs[year] ?? ""] = numbers.map { episode(year, $0) }
        }
        return FixtureNavigationClient(itemsByParent: itemsByParent)
    }

    static func episode(_ year: Int, _ number: Int, type: ItemType = .episode) -> BaseItemDto {
        let stem = "s\(year)e\(number)"
        let seasonID = seasonIDs[year] ?? ""
        return BaseItemDto(
            id: stem, name: stem, type: type,
            seriesName: name, seriesId: seriesID, seasonId: seasonID, parentId: seasonID,
            indexNumber: number, parentIndexNumber: year, overview: nil, runTimeTicks: 9_137_516_550,
            userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: 16.0 / 9.0, mediaType: "Video", libraryName: nil, productionYear: year,
            communityRating: nil, officialRating: nil, genres: ["YouTube"], taglines: nil, people: nil,
            criticRating: nil, premiereDate: nil, chapters: nil,
            path: "/media/pf/shows/\(name)/Season \(year)/\(stem).mp4", remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    static func season(_ year: Int) -> BaseItemDto {
        BaseItemDto(
            id: seasonIDs[year] ?? "", name: "Season \(year)", type: .season,
            seriesName: name, seriesId: seriesID, seasonId: nil, parentId: seriesID,
            indexNumber: year, parentIndexNumber: nil, overview: nil, runTimeTicks: nil,
            userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: year,
            communityRating: nil, officialRating: nil, genres: nil, taglines: nil, people: nil,
            criticRating: nil, premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }
}

private actor FixtureNavigationClient: PlayerEpisodeNavigationClient {
    let itemsByParent: [String: [BaseItemDto]]

    init(itemsByParent: [String: [BaseItemDto]]) {
        self.itemsByParent = itemsByParent
    }

    func getPlayerItems(parentId: String, includeTypes: [ItemType], sortBy: String, limit: Int) async throws -> ItemsResponse {
        let items = Array((itemsByParent[parentId] ?? []).prefix(limit))
        return ItemsResponse(items: items, totalRecordCount: items.count)
    }
}

private actor FailingNavigationClient: PlayerEpisodeNavigationClient {
    func getPlayerItems(parentId: String, includeTypes: [ItemType], sortBy: String, limit: Int) async throws -> ItemsResponse {
        throw URLError(.timedOut)
    }
}

@MainActor
private final class SilentReporter: PlayerPlaybackReporting {
    var lastStoppedReportEndedSession: Bool { false }

    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
}

@MainActor
private final class RecordingLoader: PlayerTransitionLoader {
    private(set) var loadedItemIDs: [String] = []

    func load(item: BaseItemDto, startFromBeginning: Bool) async {
        loadedItemIDs.append(item.id)
    }
}
