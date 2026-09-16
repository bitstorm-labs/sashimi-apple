import XCTest
@testable import Sashimi

@MainActor
final class PlaybackReportStoreTests: XCTestCase {
    private var defaults: UserDefaults?
    private var suiteName: String?

    private var testDefaults: UserDefaults {
        guard let defaults else {
            preconditionFailure("Test defaults were not configured")
        }
        return defaults
    }

    override func setUp() {
        super.setUp()
        suiteName = "PlaybackReportStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testProgressReportsCoalesceWithoutMixingServersOrItems() {
        let store = PlaybackReportStore(defaults: testDefaults)
        let first = PendingPlaybackReport(
            serverID: "server-a",
            itemID: "item-a",
            playSessionID: "session-a",
            kind: .progress,
            positionTicks: 100
        )
        let newer = PendingPlaybackReport(
            serverID: "server-a",
            itemID: "item-a",
            playSessionID: "session-a",
            kind: .progress,
            positionTicks: 200
        )
        let otherServer = PendingPlaybackReport(
            serverID: "server-b",
            itemID: "item-a",
            playSessionID: "session-a",
            kind: .progress,
            positionTicks: 300
        )

        store.enqueue(first)
        store.enqueue(newer)
        store.enqueue(otherServer)

        XCTAssertEqual(store.reports.count, 2)
        XCTAssertEqual(store.reports.first(where: { $0.serverID == "server-a" })?.positionTicks, 200)
        XCTAssertEqual(store.reports.first(where: { $0.serverID == "server-b" })?.positionTicks, 300)
    }

    func testCompletionRetryDoesNotRepeatSuccessfulStoppedPhase() async throws {
        let store = PlaybackReportStore(defaults: testDefaults)
        let delivery = PlaybackReportDelivery(store: store)
        let client = FakePlaybackReportingClient(failMarkPlayed: true)

        await delivery.sendCompletion(
            PendingPlaybackReport(
                serverID: "server-a",
                itemID: "item-a",
                playSessionID: "session-a",
                kind: .completion,
                positionTicks: 1_000
            ),
            client: client
        )

        XCTAssertEqual(store.reports.count, 1)
        XCTAssertTrue(store.reports[0].completionStoppedDelivered)
        XCTAssertFalse(store.reports[0].completionMarkedPlayed)

        await client.setFailMarkPlayed(false)
        let pending = try XCTUnwrap(store.reports.first)
        let delivered = await delivery.deliver(pending, using: client)
        XCTAssertTrue(delivered)
        // The first mark-played attempt failed; the second delivery should
        // finish the same logical event without another stopped request.
        let events = await client.events
        let stoppedCount = events.reduce(into: 0) { count, event in
            if case .stopped = event {
                count += 1
            }
        }
        XCTAssertEqual(stoppedCount, 1)
        XCTAssertTrue(store.reports.isEmpty)
    }

    func testFailedProgressRemainsPersistedUntilTheSameClientSucceeds() async throws {
        let store = PlaybackReportStore(defaults: testDefaults)
        let delivery = PlaybackReportDelivery(store: store)
        let client = FakePlaybackReportingClient(failAll: true)

        await delivery.sendProgress(
            PendingPlaybackReport(
                serverID: "server-a",
                itemID: "item-a",
                playSessionID: "session-a",
                kind: .progress,
                positionTicks: 500
            ),
            client: client
        )
        XCTAssertEqual(store.reports.count, 1)

        await client.setFailAll(false)
        let pending = try XCTUnwrap(store.reports.first)
        let delivered = await delivery.deliver(pending, using: client)
        XCTAssertTrue(delivered)
        XCTAssertTrue(store.reports.isEmpty)
    }

    func testTwoServerSessionsUseTheirOwnInjectedClients() async {
        let store = PlaybackReportStore(defaults: testDefaults)
        let delivery = PlaybackReportDelivery(store: store)
        let firstClient = FakePlaybackReportingClient()
        let secondClient = FakePlaybackReportingClient()
        let firstReporter = PlaybackSessionReporter(
            serverID: "server-a",
            client: firstClient,
            delivery: delivery
        )
        let secondReporter = PlaybackSessionReporter(
            serverID: "server-b",
            client: secondClient,
            delivery: delivery
        )

        await firstReporter.start(
            itemID: "item-a",
            positionTicks: 0,
            playSessionID: "session-a",
            playMethod: "DirectStream"
        )
        await secondReporter.start(
            itemID: "item-b",
            positionTicks: 0,
            playSessionID: "session-b",
            playMethod: "DirectStream"
        )

        let firstEvents = await firstClient.events
        let secondEvents = await secondClient.events
        XCTAssertEqual(firstEvents, [.start(itemID: "item-a")])
        XCTAssertEqual(secondEvents, [.start(itemID: "item-b")])
        XCTAssertTrue(store.reports.isEmpty)
    }

    func testManualTransitionReportsStoppedWithoutMarkingPlayed() async {
        let store = PlaybackReportStore(defaults: testDefaults)
        let delivery = PlaybackReportDelivery(store: store)
        let client = FakePlaybackReportingClient()
        let reporter = PlaybackSessionReporter(
            serverID: "server-a",
            client: client,
            delivery: delivery
        )

        await reporter.start(
            itemID: "item-a",
            positionTicks: 100,
            playSessionID: "session-a",
            playMethod: "DirectStream"
        )
        await reporter.stopped(
            itemID: "item-a",
            positionTicks: 500,
            playSessionID: "session-a"
        )
        await reporter.stopped(
            itemID: "item-a",
            positionTicks: 600,
            playSessionID: "session-a"
        )

        let events = await client.events
        XCTAssertEqual(events, [.start(itemID: "item-a"), .stopped(itemID: "item-a")])
        XCTAssertFalse(events.contains(where: { if case .markPlayed = $0 { return true }; return false }))
    }

    func testNaturalCompletionDeliversStoppedBeforeMarkPlayed() async {
        let store = PlaybackReportStore(defaults: testDefaults)
        let delivery = PlaybackReportDelivery(store: store)
        let client = FakePlaybackReportingClient()
        let reporter = PlaybackSessionReporter(serverID: "server-a", client: client, delivery: delivery)

        await reporter.start(itemID: "episode-1", positionTicks: 0, playSessionID: "session-a", playMethod: "DirectStream")
        await reporter.completed(itemID: "episode-1", positionTicks: 2_000, playSessionID: "session-a")

        let events = await client.events
        XCTAssertEqual(events, [.start(itemID: "episode-1"), .stopped(itemID: "episode-1"), .markPlayed(itemID: "episode-1")])
    }

    func testPreparedStoppedReportIsPersistedBeforeDeliveryAwaits() async throws {
        let store = PlaybackReportStore(defaults: testDefaults)
        let delivery = PlaybackReportDelivery(store: store)
        let client = FakePlaybackReportingClient()
        let reporter = PlaybackSessionReporter(serverID: "server-a", client: client, delivery: delivery)

        await reporter.start(itemID: "item-a", positionTicks: 0, playSessionID: "session-a", playMethod: "DirectStream")
        await client.setFailAll(true)
        reporter.prepareStopped(itemID: "item-a", positionTicks: 2_000, playSessionID: "session-a")

        XCTAssertEqual(store.reports.count, 1)
        XCTAssertEqual(store.reports.first?.kind, .stopped)
        await reporter.stopped(itemID: "item-a", positionTicks: 2_000, playSessionID: "session-a")
        XCTAssertEqual(store.reports.count, 1)

        await client.setFailAll(false)
        let pending = try XCTUnwrap(store.reports.first)
        let delivered = await delivery.deliver(pending, using: client)
        XCTAssertTrue(delivered)
        XCTAssertTrue(store.reports.isEmpty)
    }

    func testExpiredReportsArePrunedOnLoadAndPersisted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expired = PendingPlaybackReport(
            serverID: "server-a",
            itemID: "expired",
            playSessionID: "session-a",
            kind: .progress,
            positionTicks: 100,
            createdAt: now.addingTimeInterval(-PlaybackReportStore.staleReportInterval - 1)
        )
        let retained = PendingPlaybackReport(
            serverID: "server-a",
            itemID: "retained",
            playSessionID: "session-a",
            kind: .progress,
            positionTicks: 200,
            createdAt: now.addingTimeInterval(-PlaybackReportStore.staleReportInterval + 1)
        )

        let initialStore = PlaybackReportStore(defaults: testDefaults, now: now)
        initialStore.enqueue(expired)
        initialStore.enqueue(retained)

        let prunedStore = PlaybackReportStore(defaults: testDefaults, now: now)
        XCTAssertEqual(prunedStore.reports.map(\.itemID), ["retained"])

        // A second load proves the removal was written back rather than only
        // applied to the first in-memory instance.
        let reloadedStore = PlaybackReportStore(defaults: testDefaults, now: now)
        XCTAssertEqual(reloadedStore.reports.map(\.itemID), ["retained"])
    }

    func testReportAtRetentionBoundaryRemainsEligible() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let boundary = PendingPlaybackReport(
            serverID: "server-a",
            itemID: "boundary",
            playSessionID: "session-a",
            kind: .progress,
            positionTicks: 300,
            createdAt: now.addingTimeInterval(-PlaybackReportStore.staleReportInterval)
        )

        let store = PlaybackReportStore(defaults: testDefaults, now: now)
        store.enqueue(boundary)

        let reloadedStore = PlaybackReportStore(defaults: testDefaults, now: now)
        XCTAssertEqual(reloadedStore.reports.map(\.itemID), ["boundary"])
    }
}

private actor FakePlaybackReportingClient: PlaybackReportingClient {
    enum Event: Equatable, Sendable {
        case start(itemID: String)
        case progress(itemID: String, positionTicks: Int64)
        case stopped(itemID: String)
        case markPlayed(itemID: String)
    }

    private var failAll: Bool
    private var failMarkPlayed: Bool
    private(set) var events: [Event] = []

    init(failAll: Bool = false, failMarkPlayed: Bool = false) {
        self.failAll = failAll
        self.failMarkPlayed = failMarkPlayed
    }

    func setFailAll(_ value: Bool) {
        failAll = value
    }

    func setFailMarkPlayed(_ value: Bool) {
        failMarkPlayed = value
    }

    func reportPlaybackStart(
        itemId: String,
        positionTicks: Int64,
        playSessionId: String?,
        playMethod: String
    ) async throws {
        guard !failAll else { throw FakeError.failed }
        events.append(.start(itemID: itemId))
    }

    func reportPlaybackProgress(
        itemId: String,
        positionTicks: Int64,
        isPaused: Bool,
        playSessionId: String?
    ) async throws {
        guard !failAll else { throw FakeError.failed }
        events.append(.progress(itemID: itemId, positionTicks: positionTicks))
    }

    func reportPlaybackStopped(
        itemId: String,
        positionTicks: Int64,
        playSessionId: String?
    ) async throws {
        guard !failAll else { throw FakeError.failed }
        events.append(.stopped(itemID: itemId))
    }

    func markPlayed(itemId: String) async throws {
        guard !failAll, !failMarkPlayed else { throw FakeError.failed }
        events.append(.markPlayed(itemID: itemId))
    }

    private enum FakeError: Error {
        case failed
    }
}
