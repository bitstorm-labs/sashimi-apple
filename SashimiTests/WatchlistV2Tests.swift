import XCTest
@testable import Sashimi

/// Watchlist v2 against the plugin 0.3.0 contract
/// (plans/sashimi/2026-11-10-watchlist-v2-api.md): ＋ Add's search, the page for
/// a title the server doesn't have, and the Requests address the server sets.
@MainActor
final class WatchlistV2Tests: XCTestCase {
    private var credentials = InMemorySeerrCredentials()

    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        SeerrStubServer.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        SeerrClient.testURLProtocolClasses = [SeerrStubServer.self]
        credentials = InMemorySeerrCredentials()
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        SeerrClient.testURLProtocolClasses = []
        super.tearDown()
    }

    // MARK: Fixtures

    private func service() throws -> WatchlistService {
        WatchlistService(client: JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")),
                                                accessToken: "token", userId: "me"))
    }

    private func signedOutSeerr(defaults: UserDefaults = SeerrFixtures.defaults()) -> SeerrSession {
        SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)
    }

    /// The contract's own example.
    private let searchJSON = """
    {"query":"dune",
     "onServer":[{"type":"Movie","title":"Dune","year":2021,"tmdbId":"438631","tvdbId":null,"imdbId":"tt1160419",
       "posterUrl":"https://image.tmdb.org/t/p/original/abc.jpg","overview":"Paul.","itemId":"0123456789abcdef0123456789abcdef",
       "onWatchlist":true,"watchlistEntryId":"fedcba9876543210fedcba9876543210"}],
     "notOnServer":[{"type":"Movie","title":"Dune: Part Three","year":2026,"tmdbId":"1170608","tvdbId":null,"imdbId":null,
       "posterUrl":"https://image.tmdb.org/t/p/original/def.jpg","overview":"...","itemId":null,"onWatchlist":false,
       "watchlistEntryId":null},
       {"type":"Series","title":"Dune: Prophecy","year":2024,"tmdbId":"90228","tvdbId":"397172","imdbId":null,
       "posterUrl":null,"overview":null,"itemId":null,"onWatchlist":false,"watchlistEntryId":null,"futureField":1}]}
    """

    private let detailsJSON = """
    {"type":"Movie","title":"Sinners","year":2025,"overview":"Twin brothers.","posterUrl":"https://image.tmdb.org/p.jpg",
     "backdropUrl":"https://image.tmdb.org/b.jpg","runtimeMinutes":137,"officialRating":"R","genres":["Horror","Thriller"],
     "communityRating":7.6,"source":"TMDB","tmdbId":"1233413","imdbId":"tt31193180","onWatchlist":true,
     "watchlistEntryId":"aaaabbbbccccddddeeeeffff00001111"}
    """

    private func entryJSON(id: String) -> String {
        "{\"entry\":{\"id\":\"\(id)\",\"type\":\"Movie\",\"title\":\"Sinners\",\"tmdbId\":\"1233413\"},\"added\":true}"
    }

    private func seed(tmdb: String? = "1233413", entryId: String? = nil, kind: WatchlistKind = .movie) -> WatchlistTitleSeed {
        WatchlistTitleSeed(kind: kind, title: "Sinners", year: 2025, posterURL: URL(string: "https://image.tmdb.org/s.jpg"),
                           ids: WatchlistIds(tmdb: tmdb, imdb: "tt31193180"), watchlistEntryId: entryId)
    }

    // MARK: Search

    func testSearchDecodesBothGroupsAndIgnoresUnknownFields() throws {
        let response = try WatchlistJSON.decoder().decode(WatchlistSearchResponse.self, from: Data(searchJSON.utf8))
        XCTAssertEqual(response.query, "dune")
        XCTAssertEqual(response.onServer.map(\.itemId), ["0123456789abcdef0123456789abcdef"])
        XCTAssertEqual(response.onServer.first?.onWatchlist, true)
        XCTAssertEqual(response.notOnServer.map(\.kind), [.movie, .series])
        XCTAssertEqual(response.notOnServer[1].ids, WatchlistIds(tmdb: "90228", tvdb: "397172"))
        XCTAssertNil(response.notOnServer[1].posterURL)
    }

    /// A movie and a show can share a TMDB number: they are different hits.
    func testAHitsIdIncludesItsKind() {
        let movie = WatchlistSearchHit(kind: .movie, title: "A", ids: WatchlistIds(tmdb: "1"))
        let show = WatchlistSearchHit(kind: .series, title: "A", ids: WatchlistIds(tmdb: "1"))
        XCTAssertNotEqual(movie.id, show.id)
    }

    func testTypingSearchesWithTheTrimmedQuery() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Watchlist/Search"] = (200, searchJSON)
        let model = WatchlistSearchModel(service: try service(), store: WatchlistStore(service: try service()), debounce: .zero)
        model.text = " dune "
        await model.waitForSearch()
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.onServer.count, 1)
        XCTAssertEqual(model.notOnServer.count, 2)
        XCTAssertEqual(JellyfinRouteStub.recorded.first { $0.path == "/SashimiLists/Watchlist/Search" }?.query["q"], "dune")
    }

    func testOneLetterDoesNotSearch() async throws {
        let model = WatchlistSearchModel(service: try service(), store: WatchlistStore(service: try service()), debounce: .zero)
        model.text = "d"
        await model.waitForSearch()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(JellyfinRouteStub.recorded.isEmpty)
    }

    /// An older plugin has no search: the screen says so instead of an error.
    func testAnOlderPluginMakesSearchUnavailable() async throws {
        let model = WatchlistSearchModel(service: try service(), store: WatchlistStore(service: try service()), debounce: .zero)
        model.text = "dune"
        await model.waitForSearch()
        XCTAssertEqual(model.phase, .unavailable)
    }

    func testAServerErrorIsAFailedSearch() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Watchlist/Search"] = (500, "")
        let model = WatchlistSearchModel(service: try service(), store: WatchlistStore(service: try service()), debounce: .zero)
        model.text = "dune"
        await model.waitForSearch()
        XCTAssertEqual(model.phase, .failed)
    }

    /// ＋ posts the hit's own fields to the v1 add route and then shows "✓ Added".
    func testPlusAddsTheHitAsItIs() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Watchlist/Search"] = (200, searchJSON)
        JellyfinRouteStub.routes["POST /SashimiLists/Watchlist/Items"] = (200, entryJSON(id: "new1"))
        let model = WatchlistSearchModel(service: try service(), store: WatchlistStore(service: try service()), debounce: .zero)
        model.text = "dune"
        await model.waitForSearch()
        let hit = try XCTUnwrap(model.notOnServer.first)
        XCTAssertFalse(model.isAdded(hit))
        XCTAssertTrue(model.isAdded(try XCTUnwrap(model.onServer.first)), "already on the Watchlist")

        let added = await model.add(hit)

        XCTAssertTrue(added)
        XCTAssertTrue(model.isAdded(hit))
        let post = try XCTUnwrap(JellyfinRouteStub.recorded.first { $0.method == "POST" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(post.body)) as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "Movie")
        XCTAssertEqual(body["title"] as? String, "Dune: Part Three")
        XCTAssertEqual(body["year"] as? Int, 2026)
        XCTAssertEqual(body["tmdbId"] as? String, "1170608")
        XCTAssertEqual(body["posterUrl"] as? String, "https://image.tmdb.org/t/p/original/def.jpg")
        XCTAssertTrue(JellyfinRouteStub.recorded.contains { $0.method == "GET" && $0.path == "/SashimiLists/Watchlist" },
                      "the Watchlist reloads so its page shows the title")
    }

    func testAFailedAddIsNotShownAsAdded() async throws {
        let model = WatchlistSearchModel(service: try service(), store: WatchlistStore(service: try service()), debounce: .zero)
        let hit = WatchlistSearchHit(kind: .movie, title: "A", ids: WatchlistIds(tmdb: "1"))
        let added = await model.add(hit)
        XCTAssertFalse(added)
        XCTAssertFalse(model.isAdded(hit))
    }

    // MARK: The title page

    func testTheDetailsRequestSendsTheTypeAndEveryId() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Watchlist/Details"] = (200, detailsJSON)
        let model = WatchlistTitleModel(seed: seed(), service: try service(), store: WatchlistStore(service: try service()),
                                        seerr: signedOutSeerr())
        await model.load()
        let request = try XCTUnwrap(JellyfinRouteStub.recorded.first { $0.path == "/SashimiLists/Watchlist/Details" })
        XCTAssertEqual(request.query, ["type": "movie", "tmdbId": "1233413", "imdbId": "tt31193180"])
    }

    func testTheTitlePageShowsTheProvidersDetails() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Watchlist/Details"] = (200, detailsJSON)
        let model = WatchlistTitleModel(seed: seed(), service: try service(), store: WatchlistStore(service: try service()),
                                        seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.title, "Sinners")
        XCTAssertEqual(model.metaLine, "2025 · 2h 17m · R")
        XCTAssertEqual(model.genreLine, "Horror · Thriller · ★ 7.6")
        XCTAssertEqual(model.sourceLine, "Details from TMDB")
        XCTAssertEqual(model.overview, "Twin brothers.")
        XCTAssertEqual(model.backdropURL, URL(string: "https://image.tmdb.org/b.jpg"))
        XCTAssertTrue(model.isOnWatchlist)
        XCTAssertNil(model.libraryItem)
    }

    func testAShowSaysHowManySeasons() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Watchlist/Details"] =
            (200, "{\"type\":\"Series\",\"title\":\"The Sinner\",\"year\":2017,\"seasonCount\":4,\"onWatchlist\":false}")
        let model = WatchlistTitleModel(seed: seed(kind: .series), service: try service(),
                                        store: WatchlistStore(service: try service()), seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.metaLine, "2017 · 4 seasons")
        XCTAssertNil(model.genreLine)
        XCTAssertNil(model.sourceLine)
        XCTAssertFalse(model.isOnWatchlist)
    }

    /// No provider knows it (or an older plugin): the seed's title and poster
    /// stay, and the Watchlist toggle still works.
    func testWithoutDetailsThePageKeepsWhatItKnew() async throws {
        let model = WatchlistTitleModel(seed: seed(entryId: "e1"), service: try service(),
                                        store: WatchlistStore(service: try service()), seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.title, "Sinners")
        XCTAssertEqual(model.metaLine, "2025")
        XCTAssertEqual(model.posterURL, URL(string: "https://image.tmdb.org/s.jpg"))
        XCTAssertTrue(model.isOnWatchlist, "it came from the Watchlist")
        XCTAssertFalse(model.isLoading)
    }

    func testTheToggleAddsAndRemoves() async throws {
        JellyfinRouteStub.routes["POST /SashimiLists/Watchlist/Items"] = (200, entryJSON(id: "new1"))
        JellyfinRouteStub.routes["DELETE /SashimiLists/Watchlist/Items/new1"] = (204, "")
        let model = WatchlistTitleModel(seed: seed(), service: try service(), store: WatchlistStore(service: try service()),
                                        seerr: signedOutSeerr())
        await model.load()
        XCTAssertFalse(model.isOnWatchlist)

        let added = await model.toggleWatchlist()
        XCTAssertTrue(added)
        XCTAssertTrue(model.isOnWatchlist)
        let body = try XCTUnwrap(JellyfinRouteStub.recorded.first { $0.method == "POST" }?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["tmdbId"] as? String, "1233413")
        XCTAssertEqual(json["imdbId"] as? String, "tt31193180")

        let removed = await model.toggleWatchlist()
        XCTAssertTrue(removed)
        XCTAssertFalse(model.isOnWatchlist)
        XCTAssertTrue(JellyfinRouteStub.recorded.contains { $0.method == "DELETE" && $0.path.hasSuffix("/new1") })
    }

    func testAddingNeverRequests() async throws {
        JellyfinRouteStub.routes["POST /SashimiLists/Watchlist/Items"] = (200, entryJSON(id: "new1"))
        let model = WatchlistTitleModel(seed: seed(), service: try service(), store: WatchlistStore(service: try service()),
                                        seerr: signedOutSeerr())
        _ = await model.toggleWatchlist()
        XCTAssertTrue(SeerrStubServer.requests.isEmpty)
    }

    /// The server has it now: the library page (with Play) replaces this one.
    func testATitleTheServerHasOpensItsLibraryItem() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Watchlist/Details"] =
            (200, "{\"type\":\"Movie\",\"title\":\"Sinners\",\"itemId\":\"lib9\",\"onWatchlist\":false}")
        JellyfinRouteStub.routes["GET /Users/me/Items/lib9"] = (200, "{\"Id\":\"lib9\",\"Name\":\"Sinners\",\"Type\":\"Movie\"}")
        let model = WatchlistTitleModel(seed: seed(), service: try service(), store: WatchlistStore(service: try service()),
                                        seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.libraryItem?.id, "lib9")
    }

    func testRequestNeedsARequestsSignInAndATMDBNumber() async throws {
        let signedOut = WatchlistTitleModel(seed: seed(), service: try service(),
                                            store: WatchlistStore(service: try service()), seerr: signedOutSeerr())
        XCTAssertEqual(signedOut.requestButton, .signIn)
        let noTmdb = WatchlistTitleModel(seed: seed(tmdb: nil), service: try service(),
                                         store: WatchlistStore(service: try service()), seerr: signedOutSeerr())
        XCTAssertEqual(noTmdb.requestButton, .hidden)
    }

    func testSignedIntoRequestsAMovieOffersRequestAndAPendingOneSaysSo() async throws {
        let seerr = signedOutSeerr()
        _ = seerr.setServerAddress(SeerrFixtures.server.absoluteString)
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(id: 7),
                           headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await seerr.signInLocal(email: "test@example.com", password: "pw")
        SeerrStubServer.on("GET", "/api/v1/movie/1233413", body: "{\"id\":1233413,\"title\":\"Sinners\"}")
        let model = WatchlistTitleModel(seed: seed(), service: try service(), store: WatchlistStore(service: try service()),
                                        seerr: seerr)
        await model.load()
        XCTAssertEqual(model.requestButton, .request)

        SeerrStubServer.reset() // the first reply would repeat
        SeerrStubServer.on("GET", "/api/v1/movie/1233413",
                           body: "{\"id\":1233413,\"title\":\"Sinners\",\"mediaInfo\":{\"status\":2}}")
        await model.loadRequestState()
        XCTAssertEqual(model.requestButton, .status("Requested · waiting for approval"))
    }

    // MARK: The Watchlist page with the plugin's v2

    func testANotOnServerTileOpensTheTitlePageWithV2() async throws {
        let service = try service()
        let seerr = signedOutSeerr()
        let features = SashimiListsFeatures(service: service, seerr: seerr)
        let model = WatchlistPageViewModel(store: WatchlistStore(service: service), service: service, seerr: seerr,
                                           features: features)
        let entry = WatchlistEntry(id: "e1", kind: .movie, title: "Sinners", ids: WatchlistIds(tmdb: "1233413"))
        let tile = WatchlistTile(entry: entry, libraryItem: nil, missingTag: .notOnServer)
        XCTAssertEqual(model.action(for: tile), .explain(WatchlistText.signIntoRequests), "no v2: as before")
        XCTAssertFalse(model.canAdd)

        JellyfinRouteStub.routes["GET /SashimiLists/Config"] = (200, "{\"requestsUrl\":null}")
        await features.refresh()

        XCTAssertTrue(model.canAdd)
        XCTAssertEqual(model.action(for: tile), .openTitle(WatchlistTitleSeed(entry: entry)))
    }

    // MARK: The Requests address

    func testTheConfigDecodesTheAddressOrNone() throws {
        let decode = { (json: String) in try WatchlistJSON.decoder().decode(SashimiListsConfig.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode("{\"requestsUrl\":\"https://requests.example.com/seerr\"}").requestsURL,
                       URL(string: "https://requests.example.com/seerr"))
        XCTAssertNil(try decode("{\"requestsUrl\":null}").requestsURL)
        XCTAssertNil(try decode("{\"requestsUrl\":\"ftp://x\"}").requestsURL, "only http(s) counts")
    }

    func testTheServersAddressIsUsedAndLocked() async throws {
        let defaults = SeerrFixtures.defaults()
        let seerr = signedOutSeerr(defaults: defaults)
        XCTAssertTrue(seerr.setServerAddress("mine.example.com"))
        JellyfinRouteStub.routes["GET /SashimiLists/Config"] = (200, "{\"requestsUrl\":\"https://requests.example.com\"}")
        let features = SashimiListsFeatures(service: try service(), seerr: seerr)

        await features.refresh()

        XCTAssertTrue(features.hasWatchlistV2)
        XCTAssertTrue(seerr.isServerAddressManaged)
        XCTAssertEqual(seerr.serverURL, URL(string: "https://requests.example.com"))
        XCTAssertFalse(seerr.setServerAddress("other.example.com"), "locked while the server sets it")
        XCTAssertEqual(seerr.serverURL, URL(string: "https://requests.example.com"))

        let relaunched = signedOutSeerr(defaults: defaults)
        XCTAssertEqual(relaunched.serverURL, URL(string: "https://requests.example.com"), "kept for an offline launch")
        XCTAssertTrue(relaunched.isServerAddressManaged)
    }

    /// The setting is cleared (or the plugin is older): the device's own
    /// address, untouched all along, comes back with its box.
    func testClearingTheServersAddressBringsBackTheDevicesOwn() async throws {
        let seerr = signedOutSeerr()
        XCTAssertTrue(seerr.setServerAddress("mine.example.com"))
        JellyfinRouteStub.routes["GET /SashimiLists/Config"] = (200, "{\"requestsUrl\":\"https://requests.example.com\"}")
        let features = SashimiListsFeatures(service: try service(), seerr: seerr)
        await features.refresh()

        JellyfinRouteStub.routes["GET /SashimiLists/Config"] = (404, "")
        await features.refresh()

        XCTAssertFalse(features.hasWatchlistV2)
        XCTAssertFalse(seerr.isServerAddressManaged)
        XCTAssertEqual(seerr.serverURL, URL(string: "https://mine.example.com"))
        XCTAssertTrue(seerr.setServerAddress("other.example.com"))
    }

    /// Offline: the last answer stands, rather than flipping the address.
    func testAnUnreachableServerChangesNothing() async throws {
        let seerr = signedOutSeerr()
        JellyfinRouteStub.routes["GET /SashimiLists/Config"] = (200, "{\"requestsUrl\":\"https://requests.example.com\"}")
        let features = SashimiListsFeatures(service: try service(), seerr: seerr)
        await features.refresh()

        JellyfinRouteStub.transportFailures = ["GET /SashimiLists/Config"]
        await features.refresh()

        XCTAssertTrue(features.hasWatchlistV2)
        XCTAssertEqual(seerr.serverURL, URL(string: "https://requests.example.com"))
    }

    /// A session belongs to the server that issued it: switching to the
    /// server's address signs this device out of the old one (its cookie stays).
    func testSwitchingAddressSetsTheOldSessionAside() async throws {
        let seerr = signedOutSeerr()
        _ = seerr.setServerAddress(SeerrFixtures.server.absoluteString)
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(id: 7),
                           headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await seerr.signInLocal(email: "test@example.com", password: "pw")
        XCTAssertTrue(seerr.isActive)

        await seerr.setServerManagedAddress(URL(string: "https://requests.example.com"))

        XCTAssertFalse(seerr.isActive)
        XCTAssertNil(seerr.client)
        XCTAssertEqual(seerr.state, .notConfigured)
        XCTAssertNotNil(credentials.cookie(forKey: SeerrSession.cookieKey(for: SeerrFixtures.server)))
    }
}
