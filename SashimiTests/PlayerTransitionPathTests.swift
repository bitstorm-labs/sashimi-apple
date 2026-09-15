import XCTest
@testable import Sashimi

// Keep the end-to-end transition scenarios together so each path remains easy
// to compare while reviewing the state machine.
// swiftlint:disable type_body_length file_length

@MainActor
final class PlayerTransitionPathTests: XCTestCase {
    func testNavigationUsesOrderedNonAdjacentSeasonsForBothDirections() async {
        let current = makeItem(
            id: "season-3-episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-3",
            seasonNumber: 3,
            episodeNumber: 1
        )
        let previous = makeItem(
            id: "season-1-episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let next = makeItem(
            id: "season-5-episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-5",
            seasonNumber: 5,
            episodeNumber: 1
        )
        let nextSeasonSpecial = makeItem(
            id: "season-5-special",
            type: .episode,
            seriesId: "series",
            seasonId: "season-5",
            seasonNumber: 5,
            episodeNumber: 0
        )
        let client = FakePlayerEpisodeNavigationClient(
            itemsByParent: [
                "season-3": [current],
                "series": [
                    makeItem(id: "season-1", type: .season, seriesId: "series", seasonNumber: 1),
                    makeItem(id: "season-3", type: .season, seriesId: "series", seasonNumber: 3),
                    makeItem(id: "season-5", type: .season, seriesId: "series", seasonNumber: 5),
                ],
                "season-1": [previous],
                "season-5": [nextSeasonSpecial, next],
            ]
        )
        let viewModel = PlayerViewModel(navigationClient: client)
        viewModel.currentItem = current

        await viewModel.refreshEpisodeNavigation()

        XCTAssertEqual(viewModel.transitionState.previousEpisode?.id, previous.id)
        XCTAssertEqual(viewModel.transitionState.nextEpisode?.id, next.id)
        XCTAssertTrue(viewModel.transitionState.canPlayPrevious)
        XCTAssertTrue(viewModel.transitionState.canPlayNext)
    }

    func testSeasonRolloverFallsBackToSpecialWhenNoRegularEpisodeExists() async {
        let current = makeItem(
            id: "season-1-finale",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 8
        )
        let special = makeItem(
            id: "season-2-special",
            type: .episode,
            seriesId: "series",
            seasonId: "season-2",
            seasonNumber: 2,
            episodeNumber: 0
        )
        let client = FakePlayerEpisodeNavigationClient(
            itemsByParent: [
                "season-1": [current],
                "series": [
                    makeItem(id: "season-1", type: .season, seriesId: "series", seasonNumber: 1),
                    makeItem(id: "season-2", type: .season, seriesId: "series", seasonNumber: 2),
                ],
                "season-2": [special],
            ]
        )
        let viewModel = PlayerViewModel(navigationClient: client)
        viewModel.currentItem = current

        await viewModel.refreshEpisodeNavigation()

        XCTAssertEqual(viewModel.transitionState.nextEpisode?.id, special.id)
    }

    func testNavigationFailureKeepsFailureDistinctFromFinalEpisode() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let client = FakePlayerEpisodeNavigationClient(error: FakeNavigationError.failed)
        let viewModel = PlayerViewModel(navigationClient: client)
        viewModel.currentItem = current

        await viewModel.refreshEpisodeNavigation()

        XCTAssertEqual(viewModel.transitionState.lookupStatus, .failed)
        XCTAssertNil(viewModel.transitionState.endCard)
    }

    func testManualNextUsesProductionTransitionPathWithoutMarkingOutgoingItem() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let next = makeItem(
            id: "episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let loader = RecordingPlayerTransitionLoader()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current, next]]),
            reporter: reporter,
            transitionLoader: loader
        )
        viewModel.currentItem = current

        await viewModel.refreshEpisodeNavigation()
        await viewModel.playNextEpisode()

        XCTAssertEqual(loader.loadedItemIDs, [next.id])
        XCTAssertEqual(reporter.events, [.stopped(itemID: current.id)])
        XCTAssertFalse(reporter.events.contains { if case .completed = $0 { return true }; return false })
    }

    func testConcurrentManualNextOnlyLoadsOneSuccessor() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let next = makeItem(
            id: "episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let loader = BlockingPlayerTransitionLoader()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current, next]]),
            transitionLoader: loader
        )
        viewModel.currentItem = current

        await viewModel.refreshEpisodeNavigation()
        let first = Task { await viewModel.playNextEpisode() }
        await Task.yield()
        XCTAssertTrue(viewModel.transitionState.isTransitioning)

        let second = Task { await viewModel.playNextEpisode() }
        await Task.yield()
        loader.finish()
        await first.value
        await second.value

        XCTAssertEqual(loader.loadedItemIDs, [next.id])
        XCTAssertFalse(viewModel.transitionState.isTransitioning)
    }

    func testNaturalEndDuringEpisodeTransitionIsSuppressed() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let next = makeItem(
            id: "episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let loader = BlockingPlayerTransitionLoader()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current, next]]),
            reporter: reporter,
            transitionLoader: loader
        )
        viewModel.currentItem = current

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        let previousNavigationControls = settings.showEpisodeNavigationControls
        settings.autoPlayNextEpisode = false
        settings.showEpisodeNavigationControls = true
        defer {
            settings.autoPlayNextEpisode = previousAutoPlay
            settings.showEpisodeNavigationControls = previousNavigationControls
        }

        await viewModel.refreshEpisodeNavigation()
        let transition = Task { await viewModel.playNextEpisode() }
        await Task.yield()
        XCTAssertTrue(viewModel.transitionState.isTransitioning)

        await viewModel.handlePlaybackEnded()

        XCTAssertEqual(reporter.events, [.stopped(itemID: current.id)])
        XCTAssertFalse(viewModel.playbackEnded)

        loader.finish()
        await transition.value

        XCTAssertNil(viewModel.transitionState.endCard)
        XCTAssertFalse(viewModel.playbackEnded)
        XCTAssertFalse(viewModel.transitionState.isTransitioning)
    }

    func testEndCompletionContinuesWhenQualityChangesWhileReportSuspended() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let reporter = BlockingPlaybackCompletionReporter()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current]]),
            reporter: reporter
        )
        viewModel.currentItem = current

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        let previousNavigationControls = settings.showEpisodeNavigationControls
        settings.autoPlayNextEpisode = false
        settings.showEpisodeNavigationControls = true
        defer {
            settings.autoPlayNextEpisode = previousAutoPlay
            settings.showEpisodeNavigationControls = previousNavigationControls
        }

        let completion = Task { await viewModel.handlePlaybackEnded() }
        await fulfillment(of: [reporter.completionStarted], timeout: 2)

        await viewModel.changeQuality(.auto)
        reporter.releaseCompletion()
        await completion.value

        XCTAssertEqual(reporter.completedItemIDs, [current.id])
        XCTAssertEqual(viewModel.transitionState.endCard, .finalEpisode)
        XCTAssertTrue(viewModel.playbackEnded)
    }

    func testDelayedEndForOutgoingItemIsIgnoredAfterItemChanges() async {
        let outgoing = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let incoming = makeItem(
            id: "episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let viewModel = PlayerViewModel(reporter: reporter)
        viewModel.currentItem = incoming

        await viewModel.handlePlaybackEnded(itemID: outgoing.id, attempt: 0)

        XCTAssertTrue(reporter.events.isEmpty)
        XCTAssertFalse(viewModel.playbackEnded)
    }

    func testDelayedEndAfterStopIsIgnored() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let viewModel = PlayerViewModel(reporter: reporter)
        viewModel.currentItem = current
        let originalAttempt = 0

        await viewModel.stop()
        await viewModel.handlePlaybackEnded(itemID: current.id, attempt: originalAttempt)

        XCTAssertNil(viewModel.currentItem)
        XCTAssertTrue(reporter.events.isEmpty)
        XCTAssertFalse(viewModel.playbackEnded)
    }

    func testNaturalCompletionWithAutoplayDisabledShowsNextEndCard() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let next = makeItem(
            id: "episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let loader = RecordingPlayerTransitionLoader()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current, next]]),
            reporter: reporter,
            transitionLoader: loader
        )
        viewModel.currentItem = current

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        let previousNavigationControls = settings.showEpisodeNavigationControls
        settings.autoPlayNextEpisode = false
        settings.showEpisodeNavigationControls = true
        defer {
            settings.autoPlayNextEpisode = previousAutoPlay
            settings.showEpisodeNavigationControls = previousNavigationControls
        }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        XCTAssertEqual(viewModel.transitionState.endCard, .nextEpisode)
        XCTAssertTrue(viewModel.playbackEnded)
        XCTAssertTrue(loader.loadedItemIDs.isEmpty)
        XCTAssertEqual(reporter.events, [.completed(itemID: current.id)])
    }

    func testNaturalCompletionWithNavigationControlsDisabledDismissesWithoutEndCard() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let next = makeItem(
            id: "episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let loader = RecordingPlayerTransitionLoader()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current, next]]),
            reporter: reporter,
            transitionLoader: loader
        )
        viewModel.currentItem = current

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        let previousNavigationControls = settings.showEpisodeNavigationControls
        settings.autoPlayNextEpisode = false
        settings.showEpisodeNavigationControls = false
        defer {
            settings.autoPlayNextEpisode = previousAutoPlay
            settings.showEpisodeNavigationControls = previousNavigationControls
        }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        XCTAssertNil(viewModel.transitionState.endCard)
        XCTAssertTrue(viewModel.playbackEnded)
        XCTAssertTrue(loader.loadedItemIDs.isEmpty)
        XCTAssertEqual(reporter.events, [.completed(itemID: current.id)])
    }

    func testNaturalCompletionAutoplaysSuccessorThroughProductionTransitionPath() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let next = makeItem(
            id: "episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let loader = RecordingPlayerTransitionLoader()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current, next]]),
            reporter: reporter,
            transitionLoader: loader
        )
        viewModel.currentItem = current

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        settings.autoPlayNextEpisode = true
        defer { settings.autoPlayNextEpisode = previousAutoPlay }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        XCTAssertEqual(loader.loadedItemIDs, [next.id])
        XCTAssertEqual(reporter.events, [.completed(itemID: current.id)])
        XCTAssertNil(viewModel.transitionState.endCard)
        XCTAssertFalse(viewModel.playbackEnded)
    }

    func testNaturalCompletionOfFinalEpisodeShowsFinalEndCard() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let reporter = RecordingPlayerPlaybackReporter()
        let loader = RecordingPlayerTransitionLoader()
        let viewModel = PlayerViewModel(
            navigationClient: FakePlayerEpisodeNavigationClient(itemsByParent: ["season-1": [current]]),
            reporter: reporter,
            transitionLoader: loader
        )
        viewModel.currentItem = current

        let settings = PlaybackSettings.shared
        let previousAutoPlay = settings.autoPlayNextEpisode
        let previousNavigationControls = settings.showEpisodeNavigationControls
        settings.autoPlayNextEpisode = true
        settings.showEpisodeNavigationControls = true
        defer {
            settings.autoPlayNextEpisode = previousAutoPlay
            settings.showEpisodeNavigationControls = previousNavigationControls
        }

        await viewModel.refreshEpisodeNavigation()
        await viewModel.handlePlaybackEnded()

        XCTAssertEqual(viewModel.transitionState.endCard, .finalEpisode)
        XCTAssertTrue(viewModel.playbackEnded)
        XCTAssertTrue(loader.loadedItemIDs.isEmpty)
        XCTAssertEqual(reporter.events, [.completed(itemID: current.id)])
    }

    private func makeItem(
        id: String,
        type: ItemType,
        seriesId: String? = nil,
        seasonId: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: id,
            type: type,
            seriesName: seriesId == nil ? nil : "Series",
            seriesId: seriesId,
            seasonId: seasonId,
            parentId: seasonId,
            indexNumber: episodeNumber,
            parentIndexNumber: seasonNumber,
            overview: nil,
            runTimeTicks: nil,
            userData: nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
            libraryName: "Shows",
            productionYear: 2026,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            taglines: nil,
            people: nil,
            criticRating: nil,
            premiereDate: nil,
            chapters: nil,
            path: nil,
            remoteTrailers: nil,
            localTrailerCount: nil,
            mediaStreams: nil
        )
    }
}

private actor FakePlayerEpisodeNavigationClient: PlayerEpisodeNavigationClient {
    private let itemsByParent: [String: [BaseItemDto]]
    private let error: Error?

    init(
        itemsByParent: [String: [BaseItemDto]] = [:],
        error: Error? = nil
    ) {
        self.itemsByParent = itemsByParent
        self.error = error
    }

    func getPlayerItems(
        parentId: String,
        includeTypes: [ItemType],
        sortBy: String,
        limit: Int
    ) async throws -> ItemsResponse {
        if let error { throw error }
        let items = itemsByParent[parentId] ?? []
        return ItemsResponse(items: items, totalRecordCount: items.count)
    }
}

private enum FakeNavigationError: Error {
    case failed
}

@MainActor
private final class RecordingPlayerPlaybackReporter: PlayerPlaybackReporting {
    enum Event: Equatable {
        case start(itemID: String)
        case progress(itemID: String)
        case stopped(itemID: String)
        case completed(itemID: String)
    }

    private(set) var events: [Event] = []
    private var hasStarted = true

    func reset() {
        hasStarted = true
    }

    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}

    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {
        hasStarted = true
        events.append(.start(itemID: itemID))
    }

    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {
        guard hasStarted else { return }
        events.append(.progress(itemID: itemID))
    }

    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        guard hasStarted else { return }
        hasStarted = false
        events.append(.stopped(itemID: itemID))
    }

    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        guard hasStarted else { return }
        hasStarted = false
        events.append(.completed(itemID: itemID))
    }
}

@MainActor
private final class BlockingPlaybackCompletionReporter: PlayerPlaybackReporting {
    let completionStarted = XCTestExpectation(description: "Playback completion report started")
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var completedItemIDs: [String] = []

    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {}

    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        completedItemIDs.append(itemID)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            completionStarted.fulfill()
        }
    }

    func releaseCompletion() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecordingPlayerTransitionLoader: PlayerTransitionLoader {
    private(set) var loadedItemIDs: [String] = []

    func load(item: BaseItemDto, startFromBeginning: Bool) async {
        loadedItemIDs.append(item.id)
    }
}

@MainActor
private final class BlockingPlayerTransitionLoader: PlayerTransitionLoader {
    private(set) var loadedItemIDs: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func load(item: BaseItemDto, startFromBeginning: Bool) async {
        loadedItemIDs.append(item.id)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
