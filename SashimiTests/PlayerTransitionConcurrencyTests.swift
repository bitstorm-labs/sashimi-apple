import XCTest
@testable import Sashimi

@MainActor
final class PlayerTransitionConcurrencyTests: XCTestCase {
    func testRepeatedActionsCannotOverlapStoppedDeliveryOrLoading() async throws {
        let items = try episodes()
        let stopGate = TransitionTestGate()
        let loadGate = TransitionTestGate()
        let reporter = SuspendedTransitionReporter(stopGate: stopGate)
        let loader = SuspendedTransitionLoader(gate: loadGate)
        let model = PlayerViewModel(
            navigationClient: SuspendedNavigationClient(items: items),
            reporter: reporter, transitionLoader: loader
        )
        model.currentItem = items[1]
        await model.refreshEpisodeNavigation()

        let first = Task { await model.playNextEpisode() }
        await fulfillment(of: [stopGate.entered], timeout: 2)
        XCTAssertTrue(model.transitionState.isTransitioning)
        XCTAssertFalse(model.transitionState.canPlayPrevious)
        XCTAssertFalse(model.transitionState.canPlayNext)
        await model.playNextEpisode()
        await model.playPreviousEpisode()
        await model.replayCurrentItem()
        await model.handlePlaybackEnded()
        XCTAssertEqual(reporter.stoppedIDs, [items[1].id])
        XCTAssertTrue(reporter.completedIDs.isEmpty)
        XCTAssertTrue(loader.loadedIDs.isEmpty)

        stopGate.release()
        await fulfillment(of: [loadGate.entered], timeout: 2)
        await model.playNextEpisode()
        XCTAssertEqual(loader.loadedIDs, [items[2].id])
        loadGate.release()
        await first.value
        XCTAssertFalse(model.transitionState.isTransitioning)
    }

    func testDoneInvalidatesTransitionWaitingOnStoppedDelivery() async throws {
        let items = try episodes()
        let stopGate = TransitionTestGate()
        let reporter = SuspendedTransitionReporter(stopGate: stopGate)
        let loader = SuspendedTransitionLoader()
        let model = PlayerViewModel(
            navigationClient: SuspendedNavigationClient(items: items),
            reporter: reporter, transitionLoader: loader
        )
        model.currentItem = items[1]
        await model.refreshEpisodeNavigation()
        let next = Task { await model.playNextEpisode() }
        await fulfillment(of: [stopGate.entered], timeout: 2)
        await model.stop(reason: .userStop)
        stopGate.release()
        await next.value

        XCTAssertNil(model.currentItem)
        XCTAssertTrue(loader.loadedIDs.isEmpty)
        XCTAssertEqual(model.transitionState, .empty)
    }

    func testQualityChangePreservesPendingNavigationLookup() async throws {
        let items = try episodes()
        let gate = TransitionTestGate()
        let model = PlayerViewModel(
            client: JellyfinClient(),
            navigationClient: SuspendedNavigationClient(items: items, gate: gate)
        )
        model.currentItem = items[1]
        model.startNavigationLookup(for: items[1])
        await fulfillment(of: [gate.entered], timeout: 2)
        // An unconfigured playback client fails the stream rebuild locally;
        // the production quality teardown still runs while lookup is suspended.
        await model.changeQuality(.auto)
        let published = expectation(description: "Navigation finishes after quality teardown")
        let subscription = model.$transitionState.sink { state in
            if state.lookupStatus == .available { published.fulfill() }
        }
        gate.release()
        await fulfillment(of: [published], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(model.previousEpisode?.id, items[0].id)
        XCTAssertEqual(model.nextEpisode?.id, items[2].id)
    }

    func testReplayStartsAtBeginningWithoutDuplicatingCompletion() async throws {
        let items = try episodes()
        let reporter = SuspendedTransitionReporter()
        let loader = SuspendedTransitionLoader()
        let model = PlayerViewModel(
            navigationClient: SuspendedNavigationClient(items: items),
            reporter: reporter, transitionLoader: loader
        )
        model.currentItem = items[2]
        await model.refreshEpisodeNavigation()
        await model.handlePlaybackEnded()
        await model.replayCurrentItem()

        XCTAssertEqual(reporter.completedIDs, [items[2].id])
        XCTAssertTrue(reporter.stoppedIDs.isEmpty)
        XCTAssertEqual(loader.loadedIDs, [items[2].id])
        XCTAssertEqual(loader.startsFromBeginning, [true])
        XCTAssertFalse(model.playbackEnded)
    }

    private func episodes() throws -> [BaseItemDto] {
        try (1...3).map { index in
            let json = """
            {"Id":"episode-\(index)","Name":"Episode \(index)","Type":"Episode",
             "SeasonId":"season","IndexNumber":\(index)}
            """
            return try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
        }
    }
}

@MainActor
private final class TransitionTestGate {
    let entered = XCTestExpectation(description: "Async operation suspended")
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedNavigationClient: PlayerEpisodeNavigationClient {
    let items: [BaseItemDto]
    let gate: TransitionTestGate?

    init(items: [BaseItemDto], gate: TransitionTestGate? = nil) {
        self.items = items
        self.gate = gate
    }

    func getPlayerItems(parentId: String, includeTypes: [ItemType], sortBy: String, limit: Int) async throws -> ItemsResponse {
        await gate?.wait()
        try Task.checkCancellation()
        return ItemsResponse(items: items, totalRecordCount: items.count)
    }
}

@MainActor
private final class SuspendedTransitionReporter: PlayerPlaybackReporting {
    let stopGate: TransitionTestGate?
    var stoppedIDs: [String] = []
    var completedIDs: [String] = []

    init(stopGate: TransitionTestGate? = nil) { self.stopGate = stopGate }
    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}

    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        stoppedIDs.append(itemID)
        await stopGate?.wait()
    }

    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        completedIDs.append(itemID)
    }
}

@MainActor
private final class SuspendedTransitionLoader: PlayerTransitionLoader {
    let gate: TransitionTestGate?
    var loadedIDs: [String] = []
    var startsFromBeginning: [Bool] = []

    init(gate: TransitionTestGate? = nil) { self.gate = gate }

    func load(item: BaseItemDto, startFromBeginning: Bool) async {
        loadedIDs.append(item.id)
        startsFromBeginning.append(startFromBeginning)
        await gate?.wait()
    }
}
