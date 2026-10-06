import XCTest
@testable import Sashimi

// MARK: - Server reachability

final class ServerReachabilityTrackerTests: XCTestCase {
    func testOneFailureDoesNotGoOfflineButAsksForConfirmation() {
        var tracker = ServerReachabilityTracker()

        let changed = tracker.record(probeSucceeded: false)

        XCTAssertFalse(changed)
        XCTAssertTrue(tracker.isReachable)
        XCTAssertTrue(tracker.needsConfirmation)
    }

    func testTwoConsecutiveFailuresGoOffline() {
        var tracker = ServerReachabilityTracker()
        tracker.record(probeSucceeded: false)

        let changed = tracker.record(probeSucceeded: false)

        XCTAssertTrue(changed)
        XCTAssertFalse(tracker.isReachable)
        XCTAssertFalse(tracker.needsConfirmation)
    }

    func testSuccessBetweenFailuresResetsTheCount() {
        var tracker = ServerReachabilityTracker()
        tracker.record(probeSucceeded: false)
        tracker.record(probeSucceeded: true)

        let changed = tracker.record(probeSucceeded: false)

        XCTAssertFalse(changed)
        XCTAssertTrue(tracker.isReachable)
    }

    func testOneSuccessComesBackOnline() {
        var tracker = ServerReachabilityTracker()
        tracker.record(probeSucceeded: false)
        tracker.record(probeSucceeded: false)
        tracker.record(probeSucceeded: false)

        let changed = tracker.record(probeSucceeded: true)

        XCTAssertTrue(changed)
        XCTAssertTrue(tracker.isReachable)
        XCTAssertEqual(tracker.consecutiveFailures, 0)
    }

    func testFurtherFailuresWhileOfflineReportNoChange() {
        var tracker = ServerReachabilityTracker()
        tracker.record(probeSucceeded: false)
        tracker.record(probeSucceeded: false)

        XCTAssertFalse(tracker.record(probeSucceeded: false))
        XCTAssertFalse(tracker.isReachable)
    }

    func testConnectionStatusPrefersMissingNetworkPath() {
        XCTAssertEqual(ConnectionStatus.resolve(hasNetworkPath: false, isServerReachable: false), .noNetwork)
        XCTAssertEqual(ConnectionStatus.resolve(hasNetworkPath: false, isServerReachable: true), .noNetwork)
        XCTAssertEqual(ConnectionStatus.resolve(hasNetworkPath: true, isServerReachable: false), .serverUnreachable)
        XCTAssertEqual(ConnectionStatus.resolve(hasNetworkPath: true, isServerReachable: true), .online)
    }

    func testGatewayErrorsAndTransportFailuresIndicateUnreachableServer() {
        XCTAssertTrue(JellyfinClient.indicatesServerUnreachable(URLError(.timedOut)))
        XCTAssertTrue(JellyfinClient.indicatesServerUnreachable(URLError(.cannotConnectToHost)))
        XCTAssertTrue(JellyfinClient.indicatesServerUnreachable(JellyfinError.httpError(statusCode: 502)))
        XCTAssertFalse(JellyfinClient.indicatesServerUnreachable(JellyfinError.httpError(statusCode: 404)))
        XCTAssertFalse(JellyfinClient.indicatesServerUnreachable(JellyfinError.httpError(statusCode: 500)))
        XCTAssertFalse(JellyfinClient.indicatesServerUnreachable(URLError(.cancelled)))
    }
}

// MARK: - Offline episode order

final class OfflineEpisodeOrderTests: XCTestCase {
    private func episode(
        _ id: String,
        series: String = "show",
        season: Int?,
        episode: Int?,
        played: Bool = false,
        inProgress: Bool = false
    ) -> OfflineEpisodeKey {
        OfflineEpisodeKey(
            id: id,
            seriesKey: series,
            seasonNumber: season,
            episodeNumber: episode,
            isPlayed: played,
            isInProgress: inProgress
        )
    }

    func testNextIsTheNextDownloadedEpisodeSkippingGaps() {
        // E2 and E3 are not downloaded: E1 rolls straight into E4.
        let episodes = [
            episode("e4", season: 1, episode: 4),
            episode("e1", season: 1, episode: 1),
            episode("e5", season: 1, episode: 5)
        ]

        let adjacent = OfflineEpisodeOrder.adjacent(to: "e1", in: episodes)

        XCTAssertNil(adjacent.previous)
        XCTAssertEqual(adjacent.next?.id, "e4")
    }

    func testNextCrossesIntoTheNextDownloadedSeason() {
        let episodes = [
            episode("s1e10", season: 1, episode: 10),
            episode("s3e1", season: 3, episode: 1),
            episode("s1e9", season: 1, episode: 9)
        ]

        let adjacent = OfflineEpisodeOrder.adjacent(to: "s1e10", in: episodes)

        XCTAssertEqual(adjacent.previous?.id, "s1e9")
        XCTAssertEqual(adjacent.next?.id, "s3e1")
    }

    func testLastDownloadedEpisodeHasNoNext() {
        let episodes = [
            episode("e1", season: 1, episode: 1),
            episode("e2", season: 1, episode: 2)
        ]

        XCTAssertNil(OfflineEpisodeOrder.adjacent(to: "e2", in: episodes).next)
    }

    func testOtherShowsAreNeverOffered() {
        let episodes = [
            episode("a1", series: "a", season: 1, episode: 1),
            episode("b2", series: "b", season: 1, episode: 2)
        ]

        let adjacent = OfflineEpisodeOrder.adjacent(to: "a1", in: episodes)

        XCTAssertNil(adjacent.next)
        XCTAssertNil(adjacent.previous)
    }

    func testUnorderableEpisodesAreLeftOut() {
        let episodes = [
            episode("e1", season: 1, episode: 1),
            episode("loose", season: nil, episode: nil),
            episode("e2", season: 1, episode: 2)
        ]

        XCTAssertEqual(OfflineEpisodeOrder.adjacent(to: "e1", in: episodes).next?.id, "e2")
        XCTAssertNil(OfflineEpisodeOrder.adjacent(to: "loose", in: episodes).next)
    }

    func testUnknownCurrentEpisodeHasNoNeighbours() {
        let adjacent = OfflineEpisodeOrder.adjacent(to: "missing", in: [episode("e1", season: 1, episode: 1)])
        XCTAssertNil(adjacent.previous)
        XCTAssertNil(adjacent.next)
    }

    func testNextUpIsFirstUnplayedAfterFurthestPlayed() {
        let episodes = [
            episode("e1", season: 1, episode: 1, played: true),
            episode("e2", season: 1, episode: 2),
            episode("e3", season: 1, episode: 3, played: true),
            episode("e4", season: 1, episode: 4)
        ]

        XCTAssertEqual(OfflineEpisodeOrder.nextUp(in: episodes).map(\.id), ["e4"])
    }

    func testNextUpSkipsShowsInProgressUnstartedOrFinished() {
        let episodes = [
            episode("p1", series: "progress", season: 1, episode: 1, played: true),
            episode("p2", series: "progress", season: 1, episode: 2, inProgress: true),
            episode("u1", series: "unstarted", season: 1, episode: 1),
            episode("f1", series: "finished", season: 1, episode: 1, played: true),
            episode("n1", series: "next", season: 1, episode: 1, played: true),
            episode("n2", series: "next", season: 1, episode: 2)
        ]

        XCTAssertEqual(OfflineEpisodeOrder.nextUp(in: episodes).map(\.id), ["n2"])
    }

    func testPlayTargetPrefersInProgressThenNextUpThenFirst() {
        XCTAssertEqual(OfflineEpisodeOrder.playTarget(in: [
            episode("e1", season: 1, episode: 1, played: true),
            episode("e2", season: 1, episode: 2, inProgress: true),
            episode("e3", season: 1, episode: 3)
        ])?.id, "e2")
        XCTAssertEqual(OfflineEpisodeOrder.playTarget(in: [
            episode("e1", season: 1, episode: 1, played: true),
            episode("e2", season: 1, episode: 2)
        ])?.id, "e2")
        XCTAssertEqual(OfflineEpisodeOrder.playTarget(in: [
            episode("e2", season: 1, episode: 2),
            episode("e1", season: 1, episode: 1)
        ])?.id, "e1")
        XCTAssertEqual(OfflineEpisodeOrder.playTarget(in: [
            episode("e1", season: 1, episode: 1, played: true)
        ])?.id, "e1")
    }

    func testPlayedMeansPastNinetyPercent() {
        XCTAssertFalse(OfflinePlaybackRules.isPlayed(positionTicks: 0, runTimeTicks: 100))
        XCTAssertFalse(OfflinePlaybackRules.isPlayed(positionTicks: 89, runTimeTicks: 100))
        XCTAssertTrue(OfflinePlaybackRules.isPlayed(positionTicks: 90, runTimeTicks: 100))
        XCTAssertFalse(OfflinePlaybackRules.isPlayed(positionTicks: 50, runTimeTicks: nil))
        XCTAssertTrue(OfflinePlaybackRules.isInProgress(positionTicks: 50, runTimeTicks: 100))
        XCTAssertFalse(OfflinePlaybackRules.isInProgress(positionTicks: 95, runTimeTicks: 100))
    }
}

// MARK: - Offline episode navigation in the player

@MainActor
final class OfflinePlayerNavigationTests: XCTestCase {
    func testLocalPlaybackNavigatesAmongDownloadsWithoutTheServer() async {
        let current = makeEpisode("e1", episode: 1)
        let next = makeEpisode("e3", episode: 3)
        let source = FakeOfflineEpisodeSource(next: next)
        let viewModel = makeViewModel(source: source)
        viewModel.currentItem = current
        viewModel.isOfflinePlayback = true

        await viewModel.refreshEpisodeNavigation()

        XCTAssertEqual(viewModel.transitionState.nextEpisode?.id, "e3")
        XCTAssertEqual(viewModel.transitionState.lookupStatus, .available)
        XCTAssertEqual(source.adjacentRequests, ["e1"])
    }

    func testOfflineCompletionAutoplaysNextDownloadAndSavesFinishedPosition() async {
        let current = makeEpisode("e1", episode: 1)
        let source = FakeOfflineEpisodeSource(next: makeEpisode("e2", episode: 2))
        let loader = OfflineRecordingTransitionLoader()
        let viewModel = makeViewModel(source: source, loader: loader)
        viewModel.currentItem = current
        viewModel.isOfflinePlayback = true

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        settings.autoPlayNextEpisode = true
        defer { settings.autoPlayNextEpisode = previousAutoPlay }

        let ended = Date()
        viewModel.upNextNow = { ended }
        viewModel.upNextSleep = { _ in try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        // Through the Up Next countdown, as online.
        XCTAssertTrue(loader.loadedItemIDs.isEmpty)
        XCTAssertEqual(viewModel.episodeUpNext?.isOffline, true)
        viewModel.upNextNow = { ended.addingTimeInterval(EpisodeUpNext.countdownDuration) }
        await viewModel.upNextCountdownElapsed()

        XCTAssertEqual(loader.loadedItemIDs, ["e2"])
        XCTAssertFalse(viewModel.playbackEnded)
        // No player in the test, so the finished position is the runtime:
        // enough to count as played and sync as completed.
        XCTAssertEqual(source.recorded.map(\.itemID), ["e1"])
        XCTAssertEqual(source.recorded.first?.ticks, current.runTimeTicks)
    }

    func testOfflineCompletionWithoutAutoplayOffersTheNextDownloadOnTheEndCard() async {
        let source = FakeOfflineEpisodeSource(next: makeEpisode("e2", episode: 2))
        let loader = OfflineRecordingTransitionLoader()
        let viewModel = makeViewModel(source: source, loader: loader)
        viewModel.currentItem = makeEpisode("e1", episode: 1)
        viewModel.isOfflinePlayback = true

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        let previousControls = settings.showEpisodeNavigationControls
        settings.autoPlayNextEpisode = false
        settings.showEpisodeNavigationControls = true
        defer {
            settings.autoPlayNextEpisode = previousAutoPlay
            settings.showEpisodeNavigationControls = previousControls
        }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        XCTAssertEqual(viewModel.transitionState.endCard, .nextEpisode)
        XCTAssertTrue(viewModel.playbackEnded)
        XCTAssertTrue(loader.loadedItemIDs.isEmpty)
    }

    func testOfflineCompletionWithNoNextDownloadEndsWithoutEndCard() async {
        let source = FakeOfflineEpisodeSource(next: nil, previous: makeEpisode("e0", episode: 0))
        let loader = OfflineRecordingTransitionLoader()
        let viewModel = makeViewModel(source: source, loader: loader)
        viewModel.currentItem = makeEpisode("e1", episode: 1)
        viewModel.isOfflinePlayback = true

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        let previousControls = settings.showEpisodeNavigationControls
        settings.autoPlayNextEpisode = true
        settings.showEpisodeNavigationControls = true
        defer {
            settings.autoPlayNextEpisode = previousAutoPlay
            settings.showEpisodeNavigationControls = previousControls
        }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        // Not "Series Complete": the server may well have more episodes.
        XCTAssertNil(viewModel.transitionState.endCard)
        XCTAssertTrue(viewModel.playbackEnded)
        XCTAssertTrue(loader.loadedItemIDs.isEmpty)
    }

    func testLocalPlaybackWithoutSourceKeepsNoNavigation() {
        let viewModel = makeViewModel(source: nil)
        viewModel.isOfflinePlayback = true

        viewModel.startNavigationLookup(for: makeEpisode("e1", episode: 1))

        XCTAssertEqual(viewModel.transitionState.lookupStatus, .notApplicable)
    }

    private func makeViewModel(
        source: FakeOfflineEpisodeSource?,
        loader: OfflineRecordingTransitionLoader? = nil
    ) -> PlayerViewModel {
        let viewModel = PlayerViewModel(
            navigationClient: UnreachableNavigationClient(),
            reporter: SilentPlaybackReporter(),
            transitionLoader: loader ?? OfflineRecordingTransitionLoader()
        )
        viewModel.offlineEpisodeSource = source
        return viewModel
    }

    private func makeEpisode(_ id: String, episode: Int) -> BaseItemDto {
        BaseItemDto(
            id: id, name: id, type: .episode,
            seriesName: "Series", seriesId: "series", seasonId: "season-1", parentId: "season-1",
            indexNumber: episode, parentIndexNumber: 1, overview: nil, runTimeTicks: 600_000_000,
            userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: "Shows", productionYear: 2026,
            communityRating: nil, officialRating: nil, genres: nil, taglines: nil, people: nil,
            criticRating: nil, premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }
}

@MainActor
private final class FakeOfflineEpisodeSource: OfflineEpisodeSource {
    let next: BaseItemDto?
    let previous: BaseItemDto?
    private(set) var adjacentRequests: [String] = []
    private(set) var recorded: [(itemID: String, ticks: Int64)] = []

    init(next: BaseItemDto?, previous: BaseItemDto? = nil) {
        self.next = next
        self.previous = previous
    }

    func adjacentEpisodes(to item: BaseItemDto) -> (previous: BaseItemDto?, next: BaseItemDto?) {
        adjacentRequests.append(item.id)
        return (previous, next)
    }

    func media(for item: BaseItemDto) -> OfflinePlaybackMedia? { nil }

    func recordPosition(_ positionTicks: Int64, for item: BaseItemDto) {
        recorded.append((item.id, positionTicks))
    }
}

@MainActor
private final class OfflineRecordingTransitionLoader: PlayerTransitionLoader {
    private(set) var loadedItemIDs: [String] = []

    func load(item: BaseItemDto, startFromBeginning: Bool) async {
        loadedItemIDs.append(item.id)
    }
}

/// Offline navigation must never ask the server.
private struct UnreachableNavigationClient: PlayerEpisodeNavigationClient {
    func getPlayerItems(
        parentId: String,
        includeTypes: [ItemType],
        sortBy: String,
        limit: Int
    ) async throws -> ItemsResponse {
        XCTFail("Offline navigation queried the server for \(parentId)")
        return ItemsResponse(items: [], totalRecordCount: 0)
    }
}

@MainActor
private final class SilentPlaybackReporter: PlayerPlaybackReporting {
    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        XCTFail("Offline playback sent a stopped report for \(itemID)")
    }
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        XCTFail("Offline playback sent a completion report for \(itemID)")
    }
}
