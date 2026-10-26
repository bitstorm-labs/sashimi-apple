import XCTest
@testable import SashimiMobile

private final class EpisodesStubServer: URLProtocol {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var asked: [URL] = []
    private static let lock = NSLock()

    // Only the test's own client: the host app's client, when a logged-in
    // simulator gives it a session, must not land in `asked` (a stray request
    // there made `asked.first` the wrong one).
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.local" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let body = Self.lock.withLock {
            Self.asked.append(url)
            return Self.body
        }
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Bulk downloads choose from the server's watched state, never the page's
/// copy of it (#750): a page loaded before the user marked episodes watched
/// still says "unwatched".
final class BulkDownloadSourceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EpisodesStubServer.asked = []
        JellyfinClient.testURLProtocolClasses = [EpisodesStubServer.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func json(_ id: String, season: String, played: Bool) -> String {
        "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Episode\",\"SeriesId\":\"show\",\"SeasonId\":\"\(season)\","
            + "\"ParentIndexNumber\":3,\"UserData\":{\"Played\":\(played)}}"
    }

    private func items(_ entries: [String]) -> String {
        "{\"Items\":[\(entries.joined(separator: ","))],\"TotalRecordCount\":\(entries.count)}"
    }

    private func decode(_ entries: [String]) throws -> [BaseItemDto] {
        try JSONDecoder().decode(ItemsResponse.self, from: Data(items(entries).utf8)).items
    }

    private func client() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "t", userId: "u1")
    }

    func testUnwatchedInSeasonSkipsEpisodesMarkedWatchedAfterThePageLoaded() async throws {
        // The page: loaded before E3 and E4 were marked watched.
        let page = try decode([
            json("e3", season: "s3", played: false), json("e4", season: "s3", played: false), json("e5", season: "s3", played: false)
        ])
        // The server now.
        EpisodesStubServer.body = items([
            json("e3", season: "s3", played: true), json("e4", season: "s3", played: true), json("e5", season: "s3", played: false)
        ])

        let source = await BulkDownloadSource.episodes(
            for: .seasonUnwatched, seasonEpisodes: page, seriesId: nil, client: try client()
        )
        let chosen = BulkDownloadPlanner.select(.seasonUnwatched, from: try XCTUnwrap(source))

        XCTAssertEqual(chosen.map(\.id), ["e5"])
        let query = try XCTUnwrap(EpisodesStubServer.asked.first?.query)
        XCTAssertTrue(query.contains("SeasonId=s3"), "asks for the season shown")
    }

    func testSeriesScopesFetchTheWholeSeries() async throws {
        EpisodesStubServer.body = items([json("e1", season: "s1", played: true), json("e2", season: "s2", played: false)])

        let source = await BulkDownloadSource.episodes(
            for: .seriesUnwatched, seasonEpisodes: [], seriesId: "show", client: try client()
        )

        XCTAssertEqual(BulkDownloadPlanner.select(.seriesUnwatched, from: try XCTUnwrap(source)).map(\.id), ["e2"])
        XCTAssertFalse(EpisodesStubServer.asked.first?.query?.contains("SeasonId") ?? true)
    }

    func testASeasonWithoutServerIdsUsesThePagesEpisodes() async throws {
        let offline = try JSONDecoder().decode(
            BaseItemDto.self, from: Data("{\"Id\":\"d1\",\"Name\":\"d1\",\"Type\":\"Episode\"}".utf8)
        )
        let source = await BulkDownloadSource.episodes(for: .season, seasonEpisodes: [offline], seriesId: nil, client: try client())
        XCTAssertEqual(source?.map(\.id), ["d1"])
        XCTAssertTrue(EpisodesStubServer.asked.isEmpty)
    }

    func testTheQualityDialogNamesTheScope() {
        XCTAssertEqual(
            BulkDownloadPlanner.qualityMessage(title: BulkDownloadScope.series.dialogTitle, count: 15),
            "Download Series \u{00B7} 15 episodes"
        )
        XCTAssertEqual(BulkDownloadScope.nextUnwatched(3).dialogTitle, "Next 3 Unwatched")
        XCTAssertEqual(EpisodeDownloadScope.thisAndNext(3).title, "This and the next 3 episodes")
        XCTAssertEqual(BulkDownloadPlanner.qualityMessage(title: "", count: 1), "1 episode")
    }
}
