import XCTest
@testable import SashimiMobile

final class KeepNextEpisodesPlannerTests: XCTestCase {
    private typealias Planner = KeepNextEpisodesPlanner

    private static let downloadedAt = Date(timeIntervalSince1970: 1_000_000)
    private static let before = downloadedAt.addingTimeInterval(-3600)
    private static let after = downloadedAt.addingTimeInterval(3600)

    // MARK: - Window

    func testFreshShowQueuesTheFirstNRegularEpisodes() {
        let episodes = [
            Self.episode("s0e1", special: true),
            Self.episode("e1"), Self.episode("e2"), Self.episode("e3"), Self.episode("e4"),
        ]

        let plan = Planner.plan(episodes: episodes, downloads: [], count: 3)

        XCTAssertEqual(plan.enqueue, ["e1", "e2", "e3"])
        XCTAssertEqual(plan.delete, [])
    }

    func testWindowStartsAfterTheLastWatchedEpisodeAndIncludesInProgress() {
        // e2 was skipped, e3 watched: Next Up is e4 (in progress), not e2.
        let episodes = [
            Self.episode("e1", played: true, lastPlayed: Self.before),
            Self.episode("e2"),
            Self.episode("e3", played: true, lastPlayed: Self.before),
            Self.episode("e4"),
            Self.episode("e5"),
            Self.episode("e6"),
        ]

        let plan = Planner.plan(episodes: episodes, downloads: [], count: 2)

        XCTAssertEqual(plan.enqueue, ["e4", "e5"])
    }

    func testExistingDownloadsCountTowardTheWindow() {
        let episodes = (1...5).map { Self.episode("e\($0)") }
        let downloads = [Self.download("e1"), Self.download("e3")]

        let plan = Planner.plan(episodes: episodes, downloads: downloads, count: 3)

        XCTAssertEqual(plan.enqueue, ["e2"])
        XCTAssertEqual(plan.delete, [])
    }

    func testNothingToDoWhenTheWindowIsAlreadyDownloaded() {
        let episodes = (1...4).map { Self.episode("e\($0)") }
        let downloads = [Self.download("e1"), Self.download("e2")]

        XCTAssertTrue(Planner.plan(episodes: episodes, downloads: downloads, count: 2).isEmpty)
    }

    func testOffPlansNothing() {
        let episodes = [Self.episode("e1", played: true, lastPlayed: Self.after), Self.episode("e2")]

        XCTAssertTrue(Planner.plan(episodes: episodes, downloads: [Self.download("e1")], count: 0).isEmpty)
    }

    func testWindowStopsAtTheEndOfTheShow() {
        let episodes = [Self.episode("e1", played: true, lastPlayed: Self.before), Self.episode("e2")]

        XCTAssertEqual(Planner.plan(episodes: episodes, downloads: [], count: 5).enqueue, ["e2"])
    }

    // MARK: - Finishing an episode

    func testFinishedEpisodeIsDeletedAndTheNextOneQueued() {
        let episodes = [
            Self.episode("e1", played: true, lastPlayed: Self.after),
            Self.episode("e2"), Self.episode("e3"), Self.episode("e4"),
        ]
        let downloads = [Self.download("e1"), Self.download("e2"), Self.download("e3")]

        let plan = Planner.plan(episodes: episodes, downloads: downloads, count: 3)

        XCTAssertEqual(plan.delete, ["e1"])
        XCTAssertEqual(plan.enqueue, ["e4"])
    }

    func testEpisodeWatchedOfflineIsDeletedBeforeTheServerKnows() {
        let episodes = [Self.episode("e1"), Self.episode("e2"), Self.episode("e3")]
        let downloads = [Self.download("e1", watchedLocally: true), Self.download("e2")]

        let plan = Planner.plan(episodes: episodes, downloads: downloads, count: 2)

        XCTAssertEqual(plan.delete, ["e1"])
        XCTAssertEqual(plan.enqueue, ["e3"])
    }

    func testEpisodeDownloadedAfterItWasWatchedIsKept() {
        // Downloaded on purpose to rewatch: watched before the download existed.
        let episodes = [
            Self.episode("e1", played: true, lastPlayed: Self.before),
            Self.episode("e2"),
        ]

        let plan = Planner.plan(episodes: episodes, downloads: [Self.download("e1"), Self.download("e2")], count: 1)

        XCTAssertEqual(plan.delete, [])
    }

    func testPlayedEpisodeWithNoDateIsKept() {
        let episodes = [Self.episode("e1", played: true, lastPlayed: nil), Self.episode("e2")]

        let plan = Planner.plan(episodes: episodes, downloads: [Self.download("e1")], count: 1)

        XCTAssertEqual(plan.delete, [])
        XCTAssertEqual(plan.enqueue, ["e2"])
    }

    func testUnwatchedDownloadsBeyondTheWindowAreNotDeleted() {
        let episodes = (1...6).map { Self.episode("e\($0)") }
        let downloads = (1...6).map { Self.download("e\($0)") }

        XCTAssertTrue(Planner.plan(episodes: episodes, downloads: downloads, count: 1).isEmpty)
    }

    // MARK: - Fixtures

    private static func episode(
        _ id: String,
        special: Bool = false,
        played: Bool = false,
        lastPlayed: Date? = nil
    ) -> Planner.Episode {
        Planner.Episode(id: id, isSpecial: special, isPlayed: played, lastPlayedDate: lastPlayed)
    }

    private static func download(_ id: String, watchedLocally: Bool = false) -> Planner.Download {
        Planner.Download(itemId: id, dateAdded: downloadedAt, isWatchedLocally: watchedLocally)
    }
}

@MainActor
final class KeepNextEpisodesStoreTests: XCTestCase {
    private static let suiteName = "KeepNextEpisodesStoreTests"
    private let defaults = UserDefaults(suiteName: KeepNextEpisodesStoreTests.suiteName) ?? .standard

    override func setUp() {
        super.setUp()
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testSettingIsPerServerAndSeriesAndSurvivesRelaunch() {
        let store = KeepNextEpisodesStore(defaults: defaults)
        store.set(count: 3, quality: .medium, serverID: "serverA", seriesId: "show")

        let relaunched = KeepNextEpisodesStore(defaults: defaults)

        XCTAssertEqual(relaunched.count(serverID: "serverA", seriesId: "show"), 3)
        XCTAssertEqual(relaunched.setting(serverID: "serverA", seriesId: "show")?.quality, .medium)
        XCTAssertEqual(relaunched.count(serverID: "serverB", seriesId: "show"), 0)
        XCTAssertEqual(relaunched.count(serverID: nil, seriesId: "show"), 0)
    }

    func testChangingTheCountKeepsTheQualityAndOffRemovesIt() {
        let store = KeepNextEpisodesStore(defaults: defaults)
        store.set(count: 3, quality: .low, serverID: "s", seriesId: "show")

        store.set(count: 5, serverID: "s", seriesId: "show")
        XCTAssertEqual(store.setting(serverID: "s", seriesId: "show")?.quality, .low)
        XCTAssertEqual(store.count(serverID: "s", seriesId: "show"), 5)

        store.set(count: 0, serverID: "s", seriesId: "show")
        XCTAssertNil(store.setting(serverID: "s", seriesId: "show"))
        XCTAssertTrue(KeepNextEpisodesStore(defaults: defaults).activeSettings.isEmpty)
    }
}
