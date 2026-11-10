import XCTest
@testable import Sashimi

/// The Add to List picker's Watchlist row and Seerr mode, against a stubbed server.
@MainActor
final class AddToListWatchlistTests: XCTestCase {
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

    private func model(_ item: BaseItemDto) throws -> AddToListViewModel {
        let client = try client()
        return AddToListViewModel(
            item: item,
            service: SharedListsService(client: client),
            watchlist: WatchlistStore(service: WatchlistService(client: client)))
    }

    private func item(type: String = "Movie", providerIds: String? = "{\"Tmdb\":\"949\",\"Imdb\":\"tt0113277\"}") throws -> BaseItemDto {
        let ids = providerIds.map { ",\"ProviderIds\":\($0)" } ?? ""
        let json = "{\"Id\":\"m1\",\"Name\":\"Heat\",\"Type\":\"\(type)\"\(ids)}"
        return try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    private func serveWatchlist(entries: [String] = []) {
        JellyfinRouteStub.routes["GET \(base)"] =
            (200, "{\"cardDismissed\":false,\"entries\":[\(entries.joined(separator: ","))]}")
    }

    private func entry(_ fields: String) -> String {
        "{\"id\":\"e1\",\"type\":\"Movie\",\"title\":\"Heat\",\(fields)}"
    }

    private func serveOnePlaylist() {
        JellyfinRouteStub.routes["GET /Items"] =
            (200, "{\"Items\":[{\"Id\":\"L\",\"Name\":\"Mine\",\"Type\":\"Playlist\"}],\"TotalRecordCount\":1}")
        JellyfinRouteStub.routes["GET /SashimiLists/Owners"] = (200, #"{"L":{"OwnerUserId":"me","OwnerName":"Me"}}"#)
        JellyfinRouteStub.routes["GET /Playlists/L"] = (200, "{\"OpenAccess\":false,\"Shares\":[],\"ItemIds\":[]}")
        JellyfinRouteStub.routes["GET /Playlists/L/Items"] = (200, "{\"Items\":[],\"TotalRecordCount\":0}")
    }

    func testTheWatchlistComesBeforeYourLists() async throws {
        serveWatchlist(entries: [entry("\"tmdbId\":\"1\""), entry("\"tmdbId\":\"2\"")])
        serveOnePlaylist()
        let model = try model(try item())
        await model.load()
        XCTAssertEqual(model.watchlist, AddToListViewModel.WatchlistChoice(count: 2, alreadyOn: false))
        XCTAssertEqual(model.watchlist?.detail, "Private · 2")
        XCTAssertEqual(model.choices.map(\.list.id), ["L"])
        XCTAssertTrue(model.offersLists)
    }

    func testTheWatchlistIsMarkedWhenAnyIdAgrees() async throws {
        serveWatchlist(entries: [entry("\"imdbId\":\"tt0113277\"")])
        let model = try model(try item())
        await model.load()
        XCTAssertEqual(model.watchlist?.alreadyOn, true)
        XCTAssertEqual(model.watchlist?.detail, "Already on your Watchlist")
    }

    func testNoWatchlistRowForAnEpisode() async throws {
        serveWatchlist()
        let model = try model(try item(type: "Episode"))
        await model.load()
        XCTAssertNil(model.watchlist)
    }

    func testNoWatchlistRowForAYouTubeVideoWithoutIds() async throws {
        serveWatchlist()
        let model = try model(try item(type: "Video", providerIds: "{}"))
        await model.load()
        XCTAssertNil(model.watchlist)
        let movie = try self.model(try item(providerIds: "{}"))
        await movie.load()
        XCTAssertNil(movie.watchlist)
    }

    func testNoWatchlistRowWithoutThePlugin() async throws {
        serveOnePlaylist()
        let model = try model(try item())
        await model.load()
        XCTAssertNil(model.watchlist)
        XCTAssertEqual(model.choices.map(\.list.id), ["L"])
        XCTAssertFalse(model.isLoading)
    }

    func testAThinMovieStillGetsTheWatchlistRow() async throws {
        serveWatchlist()
        JellyfinRouteStub.routes["GET /Users/me/Items/m1"] =
            (200, "{\"Id\":\"m1\",\"Name\":\"Heat\",\"Type\":\"Movie\",\"ProviderIds\":{\"Tmdb\":\"949\"}}")
        let model = try model(try item(providerIds: nil))
        await model.load()
        XCTAssertEqual(model.watchlist, AddToListViewModel.WatchlistChoice(count: 0, alreadyOn: false))
    }

    func testASeerrTitleOffersOnlyTheWatchlist() async throws {
        serveWatchlist(entries: [entry("\"tmdbId\":\"949\"")])
        serveOnePlaylist()
        let client = try client()
        let model = AddToListViewModel(
            seerrTarget: SeerrTarget(kind: .movie, tmdbId: 949, title: "Heat"), year: 1995,
            watchlist: WatchlistStore(service: WatchlistService(client: client)))
        await model.load()
        XCTAssertFalse(model.offersLists)
        XCTAssertTrue(model.choices.isEmpty)
        XCTAssertEqual(model.titleName, "Heat")
        XCTAssertEqual(model.watchlist, AddToListViewModel.WatchlistChoice(count: 1, alreadyOn: true))
        let playlistCalls = JellyfinRouteStub.requests("GET", "/Items").filter { $0.query["IncludeItemTypes"] == "Playlist" }
        XCTAssertTrue(playlistCalls.isEmpty)
        let created = await model.create(name: "New", isPublic: false)
        XCTAssertEqual(created, "Only the Watchlist takes this title")
        XCTAssertTrue(JellyfinRouteStub.requests("POST", "/Playlists").isEmpty)
    }

    func testAddingASeerrTitlePostsItsTmdbId() async throws {
        serveWatchlist()
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"added\":true,\"entry\":\(entry("\"tmdbId\":\"949\""))}")
        let client = try client()
        let model = AddToListViewModel(
            seerrTarget: SeerrTarget(kind: .movie, tmdbId: 949, title: "Heat"), year: 1995,
            watchlist: WatchlistStore(service: WatchlistService(client: client)))
        await model.load()
        let message = await model.addToWatchlist()
        XCTAssertEqual(message, "Added to Watchlist")
        let posts = JellyfinRouteStub.requests("POST", "\(base)/Items")
        XCTAssertEqual(posts.count, 1)
        let body = try XCTUnwrap(posts.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["tmdbId"] as? String, "949")
    }

    func testAShowWithTheSameTmdbNumberIsNotTheMovie() async throws {
        let show = "{\"id\":\"e1\",\"type\":\"Series\",\"title\":\"Game\",\"tmdbId\":\"1399\"}"
        func alreadyOn(_ kind: SeerrMediaKind) async throws -> AddToListViewModel.WatchlistChoice? {
            serveWatchlist(entries: [show])
            let model = AddToListViewModel(
                seerrTarget: SeerrTarget(kind: kind, tmdbId: 1399, title: "T"), year: nil,
                watchlist: WatchlistStore(service: WatchlistService(client: try client())))
            await model.load()
            return model.watchlist
        }
        let asMovie = try await alreadyOn(.movie)
        let asShow = try await alreadyOn(.tv)
        XCTAssertEqual(asMovie?.alreadyOn, false)
        XCTAssertEqual(asShow?.alreadyOn, true)
    }
}
