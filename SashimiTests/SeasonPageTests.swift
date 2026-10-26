import XCTest
@testable import Sashimi

private func episode(
    _ number: Int,
    season: Int = 2,
    played: Bool = false,
    positionTicks: Int64 = 0
) -> BaseItemDto {
    let json = """
    {"Id":"e\(number)","Name":"Episode \(number)","Type":"Episode","SeriesId":"show","SeasonId":"s\(season)",
    "IndexNumber":\(number),"ParentIndexNumber":\(season),
    "UserData":{"Played":\(played),"PlaybackPositionTicks":\(positionTicks)}}
    """
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
}

private func item(_ json: String) -> BaseItemDto {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
}

/// The season page's Play button and header text (#760).
final class SeasonPlayTargetTests: XCTestCase {
    func testPlaysTheNextUnwatchedEpisode() throws {
        let episodes = (1...8).map { episode($0, played: $0 <= 5) }
        let target = try XCTUnwrap(SeasonPlayTarget.choose(from: episodes))
        XCTAssertEqual(target.episode.id, "e6")
        XCTAssertFalse(target.isResume)
        XCTAssertFalse(target.startsOver)
        XCTAssertEqual(target.title, "Play S2\u{00B7}E6")
    }

    func testResumesTheNextEpisodeWhenItHasProgress() throws {
        let episodes = [episode(1, played: true), episode(2, positionTicks: 9_000_000_000), episode(3)]
        let target = try XCTUnwrap(SeasonPlayTarget.choose(from: episodes))
        XCTAssertEqual(target.episode.id, "e2")
        XCTAssertTrue(target.isResume)
        XCTAssertEqual(target.title, "Resume S2\u{00B7}E2")
    }

    func testASkippedEarlyEpisodeDoesNotPullPlayBack() throws {
        let episodes = [episode(1), episode(2, played: true), episode(3, played: true), episode(4)]
        XCTAssertEqual(SeasonPlayTarget.choose(from: episodes)?.episode.id, "e4")
    }

    func testWhenTheLastEpisodeIsWatchedItFallsBackToTheFirstUnwatched() throws {
        let episodes = [episode(1, played: true), episode(2), episode(3, played: true)]
        XCTAssertEqual(SeasonPlayTarget.choose(from: episodes)?.episode.id, "e2")
    }

    func testAllWatchedPlaysEpisodeOneFromTheStart() throws {
        let episodes = (1...3).map { episode($0, played: true, positionTicks: $0 == 1 ? 5_000_000_000 : 0) }
        let target = try XCTUnwrap(SeasonPlayTarget.choose(from: episodes))
        XCTAssertEqual(target.episode.id, "e1")
        XCTAssertTrue(target.startsOver)
        XCTAssertFalse(target.isResume)
        XCTAssertEqual(target.title, "Play S2\u{00B7}E1")
    }

    func testNoEpisodesNoTarget() {
        XCTAssertNil(SeasonPlayTarget.choose(from: []))
    }

    func testTheHeaderCountsWatchedEpisodes() {
        let episodes = (1...8).map { episode($0, played: $0 <= 5) }
        XCTAssertEqual(
            SeasonPageText.subtitle(seasonName: "Season 2", episodes: episodes),
            "Season 2 \u{00B7} 8 episodes \u{00B7} 5 of 8 watched"
        )
        XCTAssertEqual(
            SeasonPageText.subtitle(seasonName: "Specials", episodes: [episode(1)]),
            "Specials \u{00B7} 1 episode \u{00B7} 0 of 1 watched"
        )
    }

    func testOfflineSeasonsHaveNoPage() {
        let season = item(#"{"Id":"s2","Name":"Season 2","Type":"Season","SeriesId":"show"}"#)
        let offline = item(#"{"Id":"offline-season-2","Name":"Season 2","Type":"Season","SeriesId":"show"}"#)
        XCTAssertTrue(SeasonPageText.canOpen(season, isConnected: true))
        XCTAssertFalse(SeasonPageText.canOpen(season, isConnected: false))
        XCTAssertFalse(SeasonPageText.canOpen(offline, isConnected: true))
    }
}

/// Series, Season and Add to Channel moved off the main row into More (#760).
final class DetailActionsTests: XCTestCase {
    private let episodeItem = item(
        #"{"Id":"e6","Name":"E6","Type":"Episode","SeriesId":"show","SeriesName":"Show","SeasonId":"s2","ParentIndexNumber":2,"IndexNumber":6}"#
    )

    func testAnEpisodesMoreMenuLeadsWithSeriesAndSeasonThenAddToChannelForAdmins() {
        let entries = DetailMenuEntry.entries(for: episodeItem, canManageChannels: true)
        XCTAssertEqual(entries, [
            .goToSeries(seriesId: "show"),
            .goToSeason(seasonId: "s2", number: 2),
            .addToChannel(ChannelTarget(itemId: "show", title: "Show"))
        ])
        XCTAssertEqual(entries.map(\.title), ["Go to Series", "Go to Season 2", "Add to Channel"])
    }

    func testAddToChannelIsForAdminsOnly() {
        let entries = DetailMenuEntry.entries(for: episodeItem, canManageChannels: false)
        XCTAssertEqual(entries.map(\.title), ["Go to Series", "Go to Season 2"])
    }

    func testMoviesAndSeriesOnlyGetAddToChannel() {
        let movie = item(#"{"Id":"m","Name":"Movie","Type":"Movie"}"#)
        let series = item(#"{"Id":"show","Name":"Show","Type":"Series"}"#)
        XCTAssertEqual(DetailMenuEntry.entries(for: movie, canManageChannels: true).map(\.title), ["Add to Channel"])
        XCTAssertEqual(DetailMenuEntry.entries(for: series, canManageChannels: true).map(\.title), ["Add to Channel"])
        XCTAssertTrue(DetailMenuEntry.entries(for: movie, canManageChannels: false).isEmpty)
    }

    func testAnEpisodesMainRowIsPlayStartOverWatchedDownloadMore() {
        XCTAssertEqual(
            DetailRowAction.mainRow(for: .episode, hasProgress: true, hasTrailer: false, supportsDownloads: true),
            [.play, .startOver, .watched, .download, .more]
        )
        // tvOS: no downloads, no progress.
        XCTAssertEqual(
            DetailRowAction.mainRow(for: .episode, hasProgress: false, hasTrailer: true, supportsDownloads: false),
            [.play, .watched, .more]
        )
    }

    func testMovieAndSeriesRows() {
        XCTAssertEqual(
            DetailRowAction.mainRow(for: .movie, hasProgress: true, hasTrailer: true, supportsDownloads: true),
            [.play, .startOver, .trailer, .watched, .download, .more]
        )
        XCTAssertEqual(
            DetailRowAction.mainRow(for: .series, hasProgress: true, hasTrailer: true, supportsDownloads: false),
            [.play, .startOver, .shuffle, .trailer, .watched, .more]
        )
    }
}

/// Answers from a "METHOD path" → (status, body) table; 404 otherwise.
private final class SeasonStubServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let (status, body) = Self.lock.withLock { Self.routes[route] ?? (404, "") }
        let url = request.url ?? URL(fileURLWithPath: "/")
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func setEpisodes(played: Bool) {
        let items = (1...3).map {
            "{\"Id\":\"e\($0)\",\"Name\":\"E\($0)\",\"Type\":\"Episode\",\"SeriesId\":\"show\",\"SeasonId\":\"s2\","
                + "\"IndexNumber\":\($0),\"ParentIndexNumber\":2,\"UserData\":{\"Played\":\(played)}}"
        }
        lock.withLock {
            routes["GET /Shows/show/Episodes"] = (200, "{\"Items\":[\(items.joined(separator: ","))],\"TotalRecordCount\":3}")
        }
    }
}

/// The season page's watched mark flips its label and the checkmarks (#760).
@MainActor
final class SeasonDetailViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SeasonStubServer.routes = [
            "GET /Users/u1/Items/s2": (200, #"{"Id":"s2","Name":"Season 2","Type":"Season","SeriesId":"show","SeriesName":"Show"}"#),
            "GET /Users/u1/Items/show": (200, #"{"Id":"show","Name":"Show","Type":"Series","Status":"Continuing"}"#)
        ]
        JellyfinClient.testURLProtocolClasses = [SeasonStubServer.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func model() throws -> SeasonDetailViewModel {
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "t", userId: "u1")
        return SeasonDetailViewModel(
            season: item(#"{"Id":"s2","Name":"Season 2","Type":"Season","SeriesId":"show"}"#),
            client: client
        )
    }

    func testMarkingTheSeasonWatchedFlipsTheButtonAndTheCheckmarks() async throws {
        SeasonStubServer.setEpisodes(played: false)
        let model = try model()
        await model.load()
        XCTAssertEqual(model.title, "Show")
        XCTAssertEqual(model.status, .continuing)
        XCTAssertEqual(model.watchAction.title, "Mark Season Watched")
        XCTAssertEqual(model.playTarget?.title, "Play S2\u{00B7}E1")

        SeasonStubServer.routes["POST /Users/u1/PlayedItems/s2"] = (200, "{}")
        SeasonStubServer.setEpisodes(played: true)
        let applied = await model.applySeasonWatch(model.watchAction)

        XCTAssertTrue(applied)
        XCTAssertEqual(model.episodes.map(\.userData?.played), [true, true, true])
        XCTAssertEqual(model.watchAction.title, "Mark Season Unwatched")
        XCTAssertEqual(model.subtitle, "Season 2 \u{00B7} 3 episodes \u{00B7} 3 of 3 watched")
    }

    func testARefusedMarkChangesNothing() async throws {
        SeasonStubServer.setEpisodes(played: false)
        let model = try model()
        await model.load()
        SeasonStubServer.routes["POST /Users/u1/PlayedItems/s2"] = (403, "")

        let applied = await model.applySeasonWatch(.markWatched)

        XCTAssertFalse(applied)
        XCTAssertEqual(model.watchAction, .markWatched)
    }

    func testAMarkMadeElsewhereUpdatesTheCheckmarks() async throws {
        SeasonStubServer.setEpisodes(played: false)
        let model = try model()
        await model.load()
        SeasonStubServer.setEpisodes(played: true)

        await model.apply(PlayedStateChange(itemId: "e2", played: true))

        XCTAssertEqual(model.episodes.map(\.userData?.played), [true, true, true])
    }
}
