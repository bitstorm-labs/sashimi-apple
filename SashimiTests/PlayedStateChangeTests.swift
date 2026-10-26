import XCTest
@testable import Sashimi

/// Answers from a "METHOD path" → (status, body) table; 404 otherwise.
private final class PlayedStubServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var asked: [String] = []
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let (status, body) = Self.lock.withLock {
            Self.asked.append(route)
            return Self.routes[route] ?? (404, "")
        }
        let url = request.url ?? URL(fileURLWithPath: "/")
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func episode(_ id: String, season: String = "s1", played: Bool = false) -> BaseItemDto {
    let json = "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Episode\",\"SeriesId\":\"show\",\"SeasonId\":\"\(season)\","
        + "\"UserData\":{\"Played\":\(played)}}"
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
}

/// A watched mark made anywhere reaches the detail screens, which refresh the
/// season on screen (#750). Before, the series page under an episode's page
/// kept the checkmarks it was loaded with.
@MainActor
final class PlayedStateChangeTests: XCTestCase {
    private var observer: NSObjectProtocol?
    private var received: [PlayedStateChange] = []

    override func setUp() {
        super.setUp()
        PlayedStubServer.routes = [:]
        PlayedStubServer.asked = []
        JellyfinClient.testURLProtocolClasses = [PlayedStubServer.self]
        received = []
        observer = NotificationCenter.default.addObserver(
            forName: .sashimiPlayedStateDidChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let change = PlayedStateChange.from(note) else { return }
            MainActor.assumeIsolated { self?.received.append(change) }
        }
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "t", userId: "u1")
    }

    func testMarkingAnnouncesTheChangeOnceTheServerAcceptsIt() async throws {
        PlayedStubServer.routes["POST /Users/u1/PlayedItems/e1"] = (200, "{}")
        PlayedStubServer.routes["DELETE /Users/u1/PlayedItems/e1"] = (200, "{}")
        let client = try client()

        try await client.markPlayed(itemId: "e1")
        try await client.markUnplayed(itemId: "e1")

        XCTAssertEqual(received, [
            PlayedStateChange(itemId: "e1", played: true),
            PlayedStateChange(itemId: "e1", played: false)
        ])
    }

    func testARefusedMarkAnnouncesNothing() async throws {
        PlayedStubServer.routes["POST /Users/u1/PlayedItems/e1"] = (403, "")
        do {
            try await client().markPlayed(itemId: "e1")
            XCTFail("a 403 throws")
        } catch {}
        XCTAssertTrue(received.isEmpty)
    }

    func testAChangeAffectsTheEpisodesItTouches() {
        let shown = [episode("e1"), episode("e2")]
        let change = { (id: String) in PlayedStateChange(itemId: id, played: true) }
        XCTAssertTrue(change("e2").affects(episodes: shown, containerIds: []), "an episode on screen")
        XCTAssertTrue(change("s1").affects(episodes: shown, containerIds: []), "their season")
        XCTAssertTrue(change("show").affects(episodes: shown, containerIds: []), "their series")
        XCTAssertTrue(change("page").affects(episodes: shown, containerIds: ["page"]), "the page's own item")
        XCTAssertFalse(change("elsewhere").affects(episodes: shown, containerIds: ["page", nil]))
    }

    func testTheSeasonOnScreenIsFetchedAgainWithTheServersMarks() async throws {
        PlayedStubServer.routes["GET /Shows/show/Episodes"] = (200,
            "{\"Items\":[{\"Id\":\"e1\",\"Name\":\"e1\",\"Type\":\"Episode\",\"SeriesId\":\"show\",\"SeasonId\":\"s1\","
            + "\"UserData\":{\"Played\":true}}],\"TotalRecordCount\":1}")
        let change = PlayedStateChange(itemId: "e1", played: true)

        let fresh = await change.refreshedEpisodes(
            showing: [episode("e1")], containerIds: [], seriesId: "show", seasonId: "s1", client: try client()
        )

        XCTAssertEqual(fresh?.map(\.userData?.played), [true])
    }

    func testNothingIsFetchedForAnUnrelatedChangeOrAnOfflineSeason() async throws {
        let client = try client()
        let unrelated = await PlayedStateChange(itemId: "other", played: true).refreshedEpisodes(
            showing: [episode("e1")], containerIds: [], seriesId: "show", seasonId: "s1", client: client
        )
        let offline = await PlayedStateChange(itemId: "e1", played: true).refreshedEpisodes(
            showing: [episode("e1")], containerIds: [], seriesId: "show", seasonId: "offline-season-1", client: client
        )
        XCTAssertNil(unrelated)
        XCTAssertNil(offline)
        XCTAssertTrue(PlayedStubServer.asked.isEmpty)
    }
}

/// The series page's watched control offers the season on screen (#749).
final class WatchedScopeEntryTests: XCTestCase {
    private func season(_ id: String, played: Bool = false) -> BaseItemDto {
        let json = "{\"Id\":\"\(id)\",\"Name\":\"Season 2\",\"Type\":\"Season\",\"UserData\":{\"Played\":\(played)}}"
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    func testOffersTheSeriesAndTheSeasonOnScreen() {
        let entries = WatchedScopeEntry.entries(
            isSeriesWatched: false, season: season("s2"), loadedEpisodes: [episode("e1", played: true)], isConnected: true
        )
        XCTAssertEqual(entries, [.series(markWatched: true), .season(season("s2"), .markUnwatched)])
        XCTAssertEqual(entries.map(\.title), ["Mark Series Watched", "Mark Season Unwatched"])
    }

    func testAWatchedSeriesOffersUnwatched() {
        let entries = WatchedScopeEntry.entries(isSeriesWatched: true, season: nil, loadedEpisodes: nil, isConnected: true)
        XCTAssertEqual(entries.map(\.title), ["Mark Series Unwatched"])
    }

    func testNoSeasonEntryOfflineOrForADownloadsSeason() {
        XCTAssertEqual(
            WatchedScopeEntry.entries(isSeriesWatched: false, season: season("s2"), loadedEpisodes: nil, isConnected: false),
            [.series(markWatched: true)]
        )
        XCTAssertEqual(
            WatchedScopeEntry.entries(
                isSeriesWatched: false, season: season("offline-season-2"), loadedEpisodes: nil, isConnected: true
            ),
            [.series(markWatched: true)]
        )
    }
}
