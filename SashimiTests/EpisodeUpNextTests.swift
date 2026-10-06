import XCTest
@testable import Sashimi

// MARK: - The pure state machine

final class EpisodeUpNextStateTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)
    private let finished = upNextEpisode("e1", 1)
    private let next = upNextEpisode("e2", 2, overview: "  The harvest fails.  ", runTimeTicks: 25_200_000_000, rating: 7.4)
    private let afterNext = upNextEpisode("e3", 3)

    private func context(
        lookup: PlayerTransitionState.LookupStatus = .available,
        next: BaseItemDto?,
        autoplay: Bool = true,
        controls: Bool = false,
        offline: Bool = false,
        pip: Bool = false
    ) -> EpisodeUpNext.Context {
        EpisodeUpNext.Context(
            finishedItem: finished,
            lookupStatus: lookup,
            nextEpisode: next,
            autoPlayNextEpisode: autoplay,
            showsEpisodeNavigationControls: controls,
            isOffline: offline,
            isPictureInPicture: pip,
            now: now
        )
    }

    private func shown(_ context: EpisodeUpNext.Context) throws -> EpisodeUpNext {
        guard case .showUpNext(let upNext) = EpisodeUpNext.decide(context) else {
            throw UpNextTestError.noScreen(EpisodeUpNext.decide(context))
        }
        return upNext
    }

    // MARK: Deciding

    func testAutoplayShowsTheScreenWithATenSecondCountdownInsteadOfStartingImmediately() throws {
        let upNext = try shown(context(next: next, autoplay: true))

        XCTAssertEqual(upNext.kind, .nextEpisode)
        XCTAssertEqual(upNext.episode?.id, "e2")
        XCTAssertEqual(upNext.countdown, .running(deadline: now.addingTimeInterval(10)))
        XCTAssertTrue(upNext.showsCountdown)
        XCTAssertEqual(upNext.following, .loading)
    }

    func testAutoplayOffShowsTheSameScreenWithoutACountdown() throws {
        let upNext = try shown(context(next: next, autoplay: false))

        XCTAssertEqual(upNext.countdown, .off)
        XCTAssertFalse(upNext.showsCountdown)
        XCTAssertFalse(upNext.isExpired(at: now.addingTimeInterval(60)))
        XCTAssertTrue(upNext.showsSkip)
    }

    /// The Up Next screen replaces auto-play; it does not depend on the
    /// navigation-controls setting that gated the old end card.
    func testNextEpisodeScreenDoesNotDependOnNavigationControlsSetting() throws {
        XCTAssertEqual(try shown(context(next: next, controls: false)).kind, .nextEpisode)
        XCTAssertEqual(try shown(context(next: next, autoplay: false, controls: false)).kind, .nextEpisode)
    }

    func testPictureInPictureWithAutoplayStartsTheNextEpisodeWithoutAScreen() throws {
        XCTAssertEqual(EpisodeUpNext.decide(context(next: next, pip: true)), .autoplayImmediately(next))
        // Without auto-play there is nothing to start; the card waits.
        XCTAssertEqual(try shown(context(next: next, autoplay: false, pip: true)).countdown, .off)
    }

    func testOfflineWithANextDownloadShowsTheScreen() throws {
        let upNext = try shown(context(next: next, offline: true))
        XCTAssertTrue(upNext.isOffline)
        XCTAssertTrue(upNext.isCountingDown)
    }

    func testOfflineWithoutANextDownloadClosesThePlayer() {
        XCTAssertEqual(EpisodeUpNext.decide(context(lookup: .unavailable, next: nil, controls: true, offline: true)), .end)
    }

    func testFinalEpisodeKeepsItsMessageAndItsSettingGate() throws {
        let upNext = try shown(context(lookup: .unavailable, next: nil, controls: true))
        XCTAssertEqual(upNext.kind, .finalEpisode)
        XCTAssertEqual(upNext.title, "There are no more episodes")
        XCTAssertNil(upNext.episode)
        XCTAssertFalse(upNext.showsSkip)
        XCTAssertFalse(upNext.showsCountdown)
        XCTAssertEqual(EpisodeUpNext.decide(context(lookup: .unavailable, next: nil, controls: false)), .end)
    }

    func testLookupFailureKeepsItsMessageAndItsSettingGate() throws {
        let upNext = try shown(context(lookup: .failed, next: nil, controls: true))
        XCTAssertEqual(upNext.kind, .lookupFailed)
        XCTAssertEqual(upNext.title, "Next episode unavailable")
        XCTAssertFalse(upNext.showsCountdown)
        XCTAssertEqual(EpisodeUpNext.decide(context(lookup: .failed, next: nil, controls: false)), .end)
    }

    // MARK: Countdown

    func testCountdownProgressAndDisplayedSeconds() throws {
        let upNext = try shown(context(next: next))

        XCTAssertEqual(upNext.displayedSeconds(at: now), 10)
        XCTAssertEqual(upNext.progress(at: now), 0, accuracy: 0.0001)
        XCTAssertEqual(upNext.displayedSeconds(at: now.addingTimeInterval(2.5)), 8)
        XCTAssertEqual(upNext.progress(at: now.addingTimeInterval(2.5)), 0.25, accuracy: 0.0001)
        XCTAssertEqual(upNext.displayedSeconds(at: now.addingTimeInterval(9.99)), 1)
        XCTAssertFalse(upNext.isExpired(at: now.addingTimeInterval(9.99)))
        XCTAssertTrue(upNext.isExpired(at: now.addingTimeInterval(10)))
        XCTAssertEqual(upNext.progress(at: now.addingTimeInterval(30)), 1, accuracy: 0.0001)
    }

    func testCancelStopsTheCountdownAndHidesSkip() throws {
        var upNext = try shown(context(next: next))
        upNext.resolveFollowing(afterNext, after: "e2")
        upNext.cancel()

        XCTAssertTrue(upNext.isCancelled)
        XCTAssertFalse(upNext.showsCountdown)
        XCTAssertFalse(upNext.isExpired(at: now.addingTimeInterval(60)))
        XCTAssertFalse(upNext.showsSkip)
        XCTAssertFalse(upNext.skip(at: now))
        XCTAssertEqual(upNext.episode?.id, "e2", "Play still plays the episode shown")
    }

    func testBackgroundPauseKeepsTheRemainingTime() throws {
        var upNext = try shown(context(next: next))
        upNext.pause(at: now.addingTimeInterval(4))

        XCTAssertEqual(upNext.countdown, .paused(remaining: 6))
        XCTAssertFalse(upNext.isExpired(at: now.addingTimeInterval(100)), "No time passes while paused")
        upNext.resume(at: now.addingTimeInterval(100))
        XCTAssertEqual(upNext.countdown, .running(deadline: now.addingTimeInterval(106)))
        XCTAssertFalse(upNext.isExpired(at: now.addingTimeInterval(105)))
        XCTAssertTrue(upNext.isExpired(at: now.addingTimeInterval(106)))
    }

    func testPauseAndResumeDoNothingWithoutARunningCountdown() throws {
        var upNext = try shown(context(next: next, autoplay: false))
        upNext.pause(at: now)
        upNext.resume(at: now)
        XCTAssertEqual(upNext.countdown, .off)
    }

    // MARK: Skip

    func testSkipMovesToTheFollowingEpisodeAndRestartsTheCountdown() throws {
        var upNext = try shown(context(next: next))
        XCTAssertFalse(upNext.canSkip, "Nothing to skip to until the look-ahead returns")
        XCTAssertTrue(upNext.showsSkip)

        upNext.resolveFollowing(afterNext, after: "e2")
        XCTAssertTrue(upNext.canSkip)
        XCTAssertTrue(upNext.skip(at: now.addingTimeInterval(7)))

        XCTAssertEqual(upNext.episode?.id, "e3")
        XCTAssertEqual(upNext.countdown, .running(deadline: now.addingTimeInterval(17)))
        XCTAssertEqual(upNext.following, .loading)
        XCTAssertEqual(upNext.skipCount, 1)
        XCTAssertEqual(upNext.episodeLabel, "S1:E3")
    }

    func testSkipIsHiddenWhenNothingFollows() throws {
        var upNext = try shown(context(next: next))
        upNext.resolveFollowing(nil, after: "e2")

        XCTAssertFalse(upNext.showsSkip)
        XCTAssertFalse(upNext.skip(at: now))
        XCTAssertEqual(upNext.episode?.id, "e2")
    }

    func testSkipWithAutoplayOffDoesNotStartACountdown() throws {
        var upNext = try shown(context(next: next, autoplay: false))
        upNext.resolveFollowing(afterNext, after: "e2")
        upNext.skip(at: now)

        XCTAssertEqual(upNext.episode?.id, "e3")
        XCTAssertEqual(upNext.countdown, .off)
    }

    func testSkipWhilePausedRestartsTheFullCountdownOnResume() throws {
        var upNext = try shown(context(next: next))
        upNext.resolveFollowing(afterNext, after: "e2")
        upNext.pause(at: now.addingTimeInterval(8))
        upNext.skip(at: now.addingTimeInterval(8))

        XCTAssertEqual(upNext.countdown, .paused(remaining: 10))
    }

    func testALateLookAheadForAnEarlierEpisodeIsIgnored() throws {
        var upNext = try shown(context(next: next))
        upNext.resolveFollowing(afterNext, after: "e2")
        upNext.skip(at: now)
        // The look-ahead for e2 answering twice must not overwrite e3's.
        upNext.resolveFollowing(upNextEpisode("e9", 9), after: "e2")

        XCTAssertEqual(upNext.following, .loading)
    }

    // MARK: Text

    func testTextForTheNextEpisode() throws {
        let upNext = try shown(context(next: next))

        XCTAssertEqual(upNext.eyebrow, "UP NEXT")
        XCTAssertEqual(upNext.title, "e2")
        XCTAssertEqual(upNext.seriesName, "Series")
        XCTAssertEqual(upNext.episodeLabel, "S1:E2")
        XCTAssertEqual(upNext.runtimeText, "42 min")
        XCTAssertEqual(upNext.message, "The harvest fails.")
        XCTAssertEqual(upNext.rating(showReviewRatings: true), 7.4)
        XCTAssertNil(upNext.rating(showReviewRatings: false), "Respects Show Review Ratings")
        XCTAssertEqual(upNext.artworkItem.id, "e2")
    }
}

// MARK: - The player's end-of-episode path

@MainActor
final class EpisodeUpNextPlayerTests: XCTestCase {
    private var savedAutoPlay = true
    private var savedControls = false
    private let start = Date(timeIntervalSinceReferenceDate: 5_000)

    override func setUp() async throws {
        savedAutoPlay = PlaybackSettings.shared.autoPlayNextEpisode
        savedControls = PlaybackSettings.shared.showEpisodeNavigationControls
        PlaybackSettings.shared.autoPlayNextEpisode = true
        PlaybackSettings.shared.showEpisodeNavigationControls = false
    }

    override func tearDown() async throws {
        PlaybackSettings.shared.autoPlayNextEpisode = savedAutoPlay
        PlaybackSettings.shared.showEpisodeNavigationControls = savedControls
    }

    private struct Harness {
        let viewModel: PlayerViewModel
        let reporter: UpNextRecordingReporter
        let loader: UpNextRecordingLoader
    }

    private func makeHarness(episodes: [BaseItemDto]) -> Harness {
        let reporter = UpNextRecordingReporter()
        let loader = UpNextRecordingLoader()
        let viewModel = PlayerViewModel(
            navigationClient: UpNextNavigationClient(itemsByParent: ["season-1": episodes]),
            reporter: reporter,
            transitionLoader: loader
        )
        viewModel.currentItem = episodes[0]
        viewModel.upNextNow = { [start] in start }
        // The countdown is driven by hand below; the real wait never ends.
        viewModel.upNextSleep = { _ in try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
        return Harness(viewModel: viewModel, reporter: reporter, loader: loader)
    }

    private func finishFirstEpisode(_ harness: Harness) async {
        await harness.viewModel.refreshEpisodeNavigation()
        await harness.viewModel.handlePlaybackEnded()
        await harness.viewModel.upNextLookupTask?.value
    }

    private func advanceClock(_ harness: Harness, by seconds: TimeInterval) {
        let date = start.addingTimeInterval(seconds)
        harness.viewModel.upNextNow = { date }
    }

    func testAutoplayShowsUpNextAndPlaysWhenTheCountdownReachesZero() async {
        let harness = makeHarness(episodes: [upNextEpisode("e1", 1), upNextEpisode("e2", 2)])
        await finishFirstEpisode(harness)

        // Not started straight away (the old behaviour): the screen is up.
        XCTAssertTrue(harness.loader.loadedItemIDs.isEmpty)
        XCTAssertEqual(harness.viewModel.episodeUpNext?.episode?.id, "e2")
        XCTAssertTrue(harness.viewModel.episodeUpNext?.isCountingDown == true)
        XCTAssertTrue(harness.viewModel.playbackEnded)
        // The finished episode was reported played before anything else.
        XCTAssertEqual(harness.reporter.events, ["completed:e1"])
        XCTAssertEqual(harness.viewModel.finishedItemIDs, ["e1"])

        advanceClock(harness, by: 9)
        await harness.viewModel.upNextCountdownElapsed()
        XCTAssertTrue(harness.loader.loadedItemIDs.isEmpty, "Not before zero")

        advanceClock(harness, by: 10)
        await harness.viewModel.upNextCountdownElapsed()
        XCTAssertEqual(harness.loader.loadedItemIDs, ["e2"])
        XCTAssertNil(harness.viewModel.episodeUpNext)
        XCTAssertEqual(harness.reporter.events, ["completed:e1"], "No second report for the finished episode")
    }

    func testCancelKeepsTheScreenAndNothingStartsOnItsOwn() async {
        let harness = makeHarness(episodes: [upNextEpisode("e1", 1), upNextEpisode("e2", 2)])
        await finishFirstEpisode(harness)

        harness.viewModel.cancelUpNext()
        advanceClock(harness, by: 60)
        await harness.viewModel.upNextCountdownElapsed()

        XCTAssertTrue(harness.loader.loadedItemIDs.isEmpty)
        XCTAssertEqual(harness.viewModel.episodeUpNext?.isCancelled, true)
        XCTAssertNil(harness.viewModel.upNextCountdownTask)

        // Play is still there after Cancel.
        await harness.viewModel.playUpNextEpisode()
        XCTAssertEqual(harness.loader.loadedItemIDs, ["e2"])
    }

    func testSkipAdvancesPastTheNextEpisodeWithoutReportingIt() async {
        let harness = makeHarness(episodes: [upNextEpisode("e1", 1), upNextEpisode("e2", 2), upNextEpisode("e3", 3)])
        await finishFirstEpisode(harness)
        XCTAssertEqual(harness.viewModel.episodeUpNext?.canSkip, true)

        advanceClock(harness, by: 6)
        harness.viewModel.skipUpNextEpisode()
        await harness.viewModel.upNextLookupTask?.value

        XCTAssertEqual(harness.viewModel.episodeUpNext?.episode?.id, "e3")
        XCTAssertEqual(harness.viewModel.episodeUpNext?.countdown, .running(deadline: start.addingTimeInterval(16)))
        XCTAssertEqual(harness.viewModel.episodeUpNext?.showsSkip, false, "Nothing after e3")

        advanceClock(harness, by: 16)
        await harness.viewModel.upNextCountdownElapsed()
        XCTAssertEqual(harness.loader.loadedItemIDs, ["e3"])
        XCTAssertEqual(harness.reporter.events, ["completed:e1"], "The skipped episode is not marked watched")
    }

    func testSkipRollsOverIntoTheNextSeason() async {
        let first = upNextEpisode("s1e1", 1)
        let finale = upNextEpisode("s1e2", 2)
        let premiere = upNextEpisode("s2e1", 1, season: 2, seasonId: "season-2")
        let reporter = UpNextRecordingReporter()
        let viewModel = PlayerViewModel(
            navigationClient: UpNextNavigationClient(itemsByParent: [
                "season-1": [first, finale],
                "season-2": [premiere],
                "series": [
                    upNextSeason("season-1", 1),
                    upNextSeason("season-2", 2)
                ]
            ]),
            reporter: reporter,
            transitionLoader: UpNextRecordingLoader()
        )
        viewModel.currentItem = first
        viewModel.upNextSleep = { _ in try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()
        await viewModel.upNextLookupTask?.value
        viewModel.skipUpNextEpisode()

        XCTAssertEqual(viewModel.episodeUpNext?.episode?.id, "s2e1")
        await viewModel.stop()
    }

    func testLeavingThePlayerCancelsTheCountdown() async {
        let harness = makeHarness(episodes: [upNextEpisode("e1", 1), upNextEpisode("e2", 2)])
        await finishFirstEpisode(harness)

        await harness.viewModel.stop()
        advanceClock(harness, by: 60)
        await harness.viewModel.upNextCountdownElapsed()

        XCTAssertNil(harness.viewModel.episodeUpNext)
        XCTAssertNil(harness.viewModel.upNextCountdownTask)
        XCTAssertTrue(harness.loader.loadedItemIDs.isEmpty)
    }

    func testBackgroundingPausesTheCountdown() async {
        let harness = makeHarness(episodes: [upNextEpisode("e1", 1), upNextEpisode("e2", 2)])
        await finishFirstEpisode(harness)

        advanceClock(harness, by: 3)
        harness.viewModel.pauseUpNextCountdown()
        XCTAssertNil(harness.viewModel.upNextCountdownTask)
        advanceClock(harness, by: 120)
        await harness.viewModel.upNextCountdownElapsed()
        XCTAssertTrue(harness.loader.loadedItemIDs.isEmpty)

        harness.viewModel.resumeUpNextCountdown()
        XCTAssertNotNil(harness.viewModel.upNextCountdownTask)
        advanceClock(harness, by: 127)
        await harness.viewModel.upNextCountdownElapsed()
        XCTAssertEqual(harness.loader.loadedItemIDs, ["e2"])
    }

    func testPictureInPictureKeepsImmediateAutoplay() async {
        let harness = makeHarness(episodes: [upNextEpisode("e1", 1), upNextEpisode("e2", 2)])
        harness.viewModel.isPictureInPictureActive = true
        await finishFirstEpisode(harness)

        XCTAssertEqual(harness.loader.loadedItemIDs, ["e2"])
        XCTAssertNil(harness.viewModel.episodeUpNext)
        // Delete-after-watching still hears about the finished item.
        XCTAssertEqual(harness.viewModel.finishedItemIDs, ["e1"])
    }

    func testRemoteNextFromTheScreenPlaysTheEpisodeShown() async {
        let harness = makeHarness(episodes: [upNextEpisode("e1", 1), upNextEpisode("e2", 2), upNextEpisode("e3", 3)])
        await finishFirstEpisode(harness)
        harness.viewModel.skipUpNextEpisode()

        await harness.viewModel.playNextEpisode()

        XCTAssertEqual(harness.loader.loadedItemIDs, ["e3"])
    }

    func testOfflineSkipOnlyMovesAmongDownloads() async {
        let source = UpNextOfflineSource(downloaded: [upNextEpisode("e1", 1), upNextEpisode("e2", 2), upNextEpisode("e5", 5)])
        let loader = UpNextRecordingLoader()
        let viewModel = PlayerViewModel(
            navigationClient: UpNextNavigationClient(itemsByParent: [:]),
            reporter: UpNextRecordingReporter(),
            transitionLoader: loader
        )
        viewModel.offlineEpisodeSource = source
        viewModel.currentItem = upNextEpisode("e1", 1)
        viewModel.isOfflinePlayback = true
        viewModel.upNextSleep = { _ in try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()
        await viewModel.upNextLookupTask?.value

        XCTAssertEqual(viewModel.episodeUpNext?.isOffline, true)
        viewModel.skipUpNextEpisode()
        XCTAssertEqual(viewModel.episodeUpNext?.episode?.id, "e5")
        await viewModel.upNextLookupTask?.value
        XCTAssertEqual(viewModel.episodeUpNext?.showsSkip, false)
        await viewModel.stop()
    }
}

// MARK: - Fixtures

private enum UpNextTestError: Error {
    case noScreen(EpisodeUpNext.Decision)
}

private func upNextEpisode(
    _ id: String,
    _ number: Int,
    season: Int = 1,
    seasonId: String = "season-1",
    overview: String? = nil,
    runTimeTicks: Int64? = 600_000_000,
    rating: Double? = nil
) -> BaseItemDto {
    BaseItemDto(
        id: id, name: id, type: .episode,
        seriesName: "Series", seriesId: "series", seasonId: seasonId, parentId: seasonId,
        indexNumber: number, parentIndexNumber: season, overview: overview, runTimeTicks: runTimeTicks,
        userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
        primaryImageAspectRatio: nil, mediaType: nil, libraryName: "Shows", productionYear: 2026,
        communityRating: rating, officialRating: nil, genres: nil, taglines: nil, people: nil,
        criticRating: nil, premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
        localTrailerCount: nil, mediaStreams: nil
    )
}

private func upNextSeason(_ id: String, _ number: Int) -> BaseItemDto {
    BaseItemDto(
        id: id, name: id, type: .season,
        seriesName: "Series", seriesId: "series", seasonId: nil, parentId: "series",
        indexNumber: number, parentIndexNumber: nil, overview: nil, runTimeTicks: nil,
        userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
        primaryImageAspectRatio: nil, mediaType: nil, libraryName: "Shows", productionYear: 2026,
        communityRating: nil, officialRating: nil, genres: nil, taglines: nil, people: nil,
        criticRating: nil, premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
        localTrailerCount: nil, mediaStreams: nil
    )
}

private actor UpNextNavigationClient: PlayerEpisodeNavigationClient {
    let itemsByParent: [String: [BaseItemDto]]

    init(itemsByParent: [String: [BaseItemDto]]) {
        self.itemsByParent = itemsByParent
    }

    func getPlayerItems(parentId: String, includeTypes: [ItemType], sortBy: String, limit: Int) async throws -> ItemsResponse {
        let items = itemsByParent[parentId] ?? []
        return ItemsResponse(items: items, totalRecordCount: items.count)
    }
}

@MainActor
private final class UpNextRecordingReporter: PlayerPlaybackReporting {
    private(set) var events: [String] = []
    var lastStoppedReportEndedSession: Bool { false }

    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        events.append("stopped:\(itemID)")
    }
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        events.append("completed:\(itemID)")
    }
}

@MainActor
private final class UpNextRecordingLoader: PlayerTransitionLoader {
    private(set) var loadedItemIDs: [String] = []

    func load(item: BaseItemDto, startFromBeginning: Bool) async {
        loadedItemIDs.append(item.id)
    }
}

@MainActor
private final class UpNextOfflineSource: OfflineEpisodeSource {
    let downloaded: [BaseItemDto]

    init(downloaded: [BaseItemDto]) {
        self.downloaded = downloaded
    }

    func adjacentEpisodes(to item: BaseItemDto) -> (previous: BaseItemDto?, next: BaseItemDto?) {
        guard let index = downloaded.firstIndex(where: { $0.id == item.id }) else { return (nil, nil) }
        let previous = index > 0 ? downloaded[index - 1] : nil
        let next = index + 1 < downloaded.count ? downloaded[index + 1] : nil
        return (previous, next)
    }

    func media(for item: BaseItemDto) -> OfflinePlaybackMedia? { nil }
    func recordPosition(_ positionTicks: Int64, for item: BaseItemDto) {}
}
