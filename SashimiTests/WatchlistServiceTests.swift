import XCTest
@testable import Sashimi

/// The Watchlist client and service against a stubbed server.
@MainActor
final class WatchlistServiceTests: XCTestCase {
    private let base = "/SashimiLists/Watchlist"

    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
    }

    private func service() throws -> WatchlistService {
        WatchlistService(client: try client())
    }

    private func entryJSON(id: String = "e1", itemId: String? = nil) -> String {
        let item = itemId.map { ",\"itemId\":\"\($0)\"" } ?? ""
        return "{\"id\":\"\(id)\",\"type\":\"Movie\",\"title\":\"Heat\",\"year\":1995,\"tmdbId\":\"949\"\(item)}"
    }

    private func item(_ type: String, providerIds: String? = nil) throws -> BaseItemDto {
        let ids = providerIds.map { ",\"ProviderIds\":\($0)" } ?? ""
        let json = "{\"Id\":\"m1\",\"Name\":\"Heat\",\"Type\":\"\(type)\",\"ProductionYear\":1995\(ids)}"
        return try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    private func postedJSON(_ path: String) throws -> [String: Any] {
        let body = try XCTUnwrap(JellyfinRouteStub.requests("POST", path).last?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testLoadReturnsNilWhenTheServerHasNoWatchlistRoute() async throws {
        let response = try await service().load()
        XCTAssertNil(response)
    }

    func testLoadDecodesTheWatchlist() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, """
        {"plex":{"username":"marge","needsReconnect":false},"cardDismissed":true,"entries":[\(entryJSON())]}
        """)
        let loaded = try await service().load()
        let response = try XCTUnwrap(loaded)
        XCTAssertEqual(response.plex?.username, "marge")
        XCTAssertTrue(response.cardDismissed)
        XCTAssertEqual(response.entries.map(\.id), ["e1"])
    }

    func testLoadStillThrowsOnOtherFailures() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (403, "")
        do {
            _ = try await service().load()
            XCTFail("expected a throw")
        } catch JellyfinError.httpError(let code) {
            XCTAssertEqual(code, 403)
        }
    }

    func testAddPostsTheEntryAndReportsAlreadyThere() async throws {
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"entry\":\(entryJSON()),\"added\":false}")
        let movie = try item("Movie", providerIds: "{\"Tmdb\":\"949\"}")
        let result = try await service().add(movie)
        XCTAssertFalse(result.added)
        XCTAssertEqual(try postedJSON("\(base)/Items")["tmdbId"] as? String, "949")
    }

    func testAThinItemIsFetchedForItsProviderIds() async throws {
        JellyfinRouteStub.routes["GET /Users/me/Items/m1"] = (200, "{\"Id\":\"m1\",\"Name\":\"Heat\",\"Type\":\"Movie\",\"ProviderIds\":{\"Tmdb\":\"9\"}}")
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"entry\":\(entryJSON()),\"added\":true}")
        let thin = try item("Movie")
        _ = try await service().add(thin)
        XCTAssertEqual(try postedJSON("\(base)/Items")["tmdbId"] as? String, "9")
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/Users/me/Items/m1").count, 1)
    }

    func testAnEpisodeIsNeverSentToTheWatchlist() async throws {
        let episode = try item("Episode", providerIds: "{\"Tmdb\":\"9\"}")
        do {
            _ = try await service().add(episode)
            XCTFail("expected notEligible")
        } catch WatchlistError.notEligible {
            // expected
        }
        XCTAssertTrue(JellyfinRouteStub.requests("POST", "\(base)/Items").isEmpty)
    }

    func testAPlexTokenPlexRejectsIsRejected() async throws {
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (422, "{}")
        let result = try await client().linkWatchlistPlex(token: "bad", replace: false)
        XCTAssertEqual(result, .rejected)
    }

    func testPlexUnreachableIsNotARejection() async throws {
        let client = try client()
        for status in [503, 500] {
            JellyfinRouteStub.recorded = []
            JellyfinRouteStub.routes["POST \(base)/Plex"] = (status, "{\"error\":\"plex.tv unreachable\"}")
            let result = try await client.linkWatchlistPlex(token: "t", replace: false)
            XCTAssertEqual(result, .plexUnreachable, "status \(status)")
            XCTAssertEqual(JellyfinRouteStub.requests("POST", "\(base)/Plex").count, 1, "status \(status) is never retried")
        }
    }

    func testPlexConflictCarriesBothUsernames() async throws {
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (409, "{\"username\":\"marge\",\"newUsername\":\"chad\"}")
        let result = try await client().linkWatchlistPlex(token: "t", replace: false)
        XCTAssertEqual(result, .conflict(currentUsername: "marge", newUsername: "chad"))
    }

    func testAnOlderPluginsConflictHasNoNewUsername() async throws {
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (409, "{\"username\":\"marge\"}")
        let result = try await client().linkWatchlistPlex(token: "t", replace: false)
        XCTAssertEqual(result, .conflict(currentUsername: "marge", newUsername: nil))
    }

    func testLinkSucceedsWithTheLinkedAccount() async throws {
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let result = try await client().linkWatchlistPlex(token: "t", replace: true)
        XCTAssertEqual(result, .linked(PlexLink(username: "marge", needsReconnect: false)))
    }

    func testLinkOtherFailuresThrow() async throws {
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (403, "")
        do {
            _ = try await client().linkWatchlistPlex(token: "t", replace: false)
            XCTFail("expected a throw")
        } catch JellyfinError.httpError(let code) {
            XCTAssertEqual(code, 403)
        }
        XCTAssertEqual(JellyfinRouteStub.requests("POST", "\(base)/Plex").count, 1, "never retried")
    }

    func testLinkSendsTokenAndReplaceInTheBody() async throws {
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        _ = try await client().linkWatchlistPlex(token: "tok-1", replace: true)
        let body = try postedJSON("\(base)/Plex")
        XCTAssertEqual(body["token"] as? String, "tok-1")
        XCTAssertEqual(body["replace"] as? Bool, true)
    }

    func testLibraryAddsSendNoPosterUrl() async throws {
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"entry\":\(entryJSON()),\"added\":true}")
        _ = try await service().add(try item("Movie", providerIds: "{\"Tmdb\":\"949\"}"))
        XCTAssertNil(try postedJSON("\(base)/Items")["posterUrl"])
    }

    func testRemoveAndUnlinkAndDismissUseTheirRoutes() async throws {
        JellyfinRouteStub.routes["DELETE \(base)/Items/e1"] = (204, "")
        JellyfinRouteStub.routes["DELETE \(base)/Plex"] = (204, "")
        JellyfinRouteStub.routes["POST \(base)/DismissCard"] = (204, "")
        let entry = WatchlistEntry(id: "e1", kind: .movie, title: "Heat", ids: WatchlistIds(tmdb: "949"))
        try await service().remove(entry)
        try await client().unlinkWatchlistPlex()
        try await client().dismissWatchlistCard()
        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", "\(base)/Items/e1").count, 1)
        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", "\(base)/Plex").count, 1)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", "\(base)/DismissCard").count, 1)
    }

    func testSeerrAddsCarryThePosterAndTmdbId() async throws {
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"entry\":\(entryJSON()),\"added\":true}")
        let target = SeerrTarget(kind: .movie, tmdbId: 949, title: "Heat", posterPath: "/p.jpg")
        _ = try await service().add(target, year: 1995)
        let body = try postedJSON("\(base)/Items")
        XCTAssertEqual(body["tmdbId"] as? String, "949")
        XCTAssertEqual(body["year"] as? Int, 1995)
        XCTAssertNotNil(body["posterUrl"])
    }

    func testLibraryItemsAreFetchedInOneCall() async throws {
        JellyfinRouteStub.routes["GET /Users/me/Items"] = (200, """
        {"Items":[{"Id":"a","Name":"A","Type":"Movie"},{"Id":"b","Name":"B","Type":"Movie"}],"TotalRecordCount":2}
        """)
        let entries = [
            WatchlistEntry(id: "1", kind: .movie, title: "A", ids: WatchlistIds(tmdb: "1"), itemId: "a"),
            WatchlistEntry(id: "2", kind: .movie, title: "B", ids: WatchlistIds(tmdb: "2"), itemId: "b"),
            WatchlistEntry(id: "3", kind: .movie, title: "C", ids: WatchlistIds(tmdb: "3"))
        ]
        let found = try await service().libraryItems(for: entries)
        XCTAssertEqual(Set(found.keys), ["a", "b"])
        let calls = JellyfinRouteStub.requests("GET", "/Users/me/Items")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Set((calls.first?.query["Ids"] ?? "").split(separator: ",").map(String.init)), ["a", "b"])
    }

    func testLibraryItemsFailureGivesNothing() async throws {
        JellyfinRouteStub.routes["GET /Users/me/Items"] = (403, "")
        let entries = [WatchlistEntry(id: "1", kind: .movie, title: "A", ids: WatchlistIds(tmdb: "1"), itemId: "a")]
        let found = try await service().libraryItems(for: entries)
        XCTAssertTrue(found.isEmpty)
    }
}
