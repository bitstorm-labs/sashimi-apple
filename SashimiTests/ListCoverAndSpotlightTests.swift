import XCTest
@testable import Sashimi

/// Watchlist v2 §6: the poster-stack cover on the Lists page, and the
/// Spotlight that a list's page shows for its focused or selected title.
@MainActor
final class ListCoverAndSpotlightTests: XCTestCase {
    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func item(_ json: String) throws -> BaseItemDto {
        try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    private func entry(_ id: String, itemId: String? = nil, poster: String? = nil, kind: WatchlistKind = .movie,
                       year: Int? = nil, tmdb: String? = nil) -> WatchlistEntry {
        WatchlistEntry(id: id, kind: kind, title: "Title \(id)", year: year, posterURL: poster.flatMap(URL.init(string:)),
                       ids: WatchlistIds(tmdb: tmdb ?? id), itemId: itemId)
    }

    // MARK: The stack's layers

    func testOneTitleIsASinglePoster() {
        let layers = PosterStack.layers(count: 1, fanned: false)
        XCTAssertEqual(layers.map(\.index), [0])
        XCTAssertEqual(layers.first?.rotation, 0)
        XCTAssertEqual(layers.first?.scale, 1)
        XCTAssertEqual(layers.first?.opacity, 1)
    }

    func testTwoTitlesAreATwoPosterStackDrawnBackToFront() {
        XCTAssertEqual(PosterStack.layers(count: 2, fanned: false).map(\.index), [1, 0])
    }

    /// The front poster is full size and sharp; the next two sit behind it,
    /// smaller, to the right, rotated about 3° and 7°, the back one faded.
    func testThreeTitlesFanTheNextTwoBehindTheFirst() throws {
        let layers = PosterStack.layers(count: 3, fanned: false)
        XCTAssertEqual(layers.map(\.index), [2, 1, 0])
        XCTAssertEqual(layers.map(\.rotation), [7, 3, 0])
        let back = layers[0], middle = layers[1], front = layers[2]
        XCTAssertLessThan(back.scale, middle.scale)
        XCTAssertLessThan(middle.scale, front.scale)
        XCTAssertGreaterThan(back.xOffset, middle.xOffset)
        XCTAssertGreaterThan(middle.xOffset, front.xOffset)
        XCTAssertLessThan(back.opacity, 1)
        XCTAssertEqual(middle.opacity, 1)
        XCTAssertEqual(front.opacity, 1)
    }

    func testMoreThanThreeTitlesStillShowThree() {
        XCTAssertEqual(PosterStack.layers(count: 7, fanned: false).count, 3)
        XCTAssertEqual(PosterStack.layers(count: 0, fanned: false), [], "an empty list draws the placeholder")
    }

    /// On focus or hover the stack fans out a little; the front poster stays put.
    func testFocusFansTheStackOut() {
        let still = PosterStack.layers(count: 3, fanned: false)
        let fanned = PosterStack.layers(count: 3, fanned: true)
        XCTAssertEqual(fanned[2], still[2])
        for index in 0..<2 {
            XCTAssertGreaterThan(fanned[index].xOffset, still[index].xOffset)
            XCTAssertGreaterThan(fanned[index].rotation, still[index].rotation)
        }
    }

    // MARK: Which posters a cover uses

    func testAListsCoverIsItsFirstThreeDifferentTitles() {
        let movie = { (id: String) in ListEntry(itemId: id, type: .movie, seriesId: nil, season: nil, episode: nil) }
        let episode = ListEntry(itemId: "e2", type: .episode, seriesId: "m1", season: 1, episode: 2)
        XCTAssertEqual(SharedLists.coverPosterIds([movie("m1"), episode, movie("m2"), movie("m3"), movie("m4")]),
                       ["m1", "m2", "m3"])
        XCTAssertEqual(SharedLists.coverPosterIds([movie("m1"), movie("m2")]), ["m1", "m2"],
                       "two titles are a two-poster stack, not the first alone")
    }

    func testAListCardsPostersAreItsServersOwnAndNeverDimmed() throws {
        let list = SharedList(id: "l", name: "Picks", ownerId: nil, isPublic: false, imageTag: nil)
        let card = ListCard(list: list, ownerName: nil, count: 2, coverIds: ["a", "b"])
        XCTAssertEqual(card.coverPosters, [ListCoverPoster(artwork: .library(itemId: "a"), title: "", isDimmed: false),
                                           ListCoverPoster(artwork: .library(itemId: "b"), title: "", isDimmed: false)])
    }

    /// The Watchlist's cover uses its first three entries; titles the server
    /// doesn't have show their poster dimmed.
    func testTheWatchlistCoverIsItsFirstThreeEntriesWithMissingOnesDimmed() throws {
        let poster = "https://image.tmdb.org/t/p/w342/a.jpg"
        let entries = [entry("1", itemId: "lib1"), entry("2", poster: poster), entry("3", itemId: "lib3"),
                       entry("4", itemId: "lib4")]
        let card = WatchlistCardInfo(WatchlistResponse(plex: nil, cardDismissed: false, entries: entries))
        XCTAssertEqual(card.cover.map(\.isDimmed), [false, true, false])
        XCTAssertEqual(card.cover.map(\.artwork), [.library(itemId: "lib1"), .remote(try XCTUnwrap(URL(string: poster))),
                                                   .library(itemId: "lib3")])
        XCTAssertEqual(card.cover.map(\.title), ["Title 1", "Title 2", "Title 3"])
    }

    // MARK: The Spotlight

    func testTheEyebrowNamesTheListWhoMadeItAndHowMany() {
        XCTAssertEqual(ListText.eyebrow(listName: "Picks", ownerName: "Me", isOwn: true, count: 3), "Picks · 3 titles")
        XCTAssertEqual(ListText.eyebrow(listName: "Christmas Movies", ownerName: "Marge", isOwn: false, count: 14),
                       "Christmas Movies · Marge · 14 titles")
        XCTAssertEqual(ListText.eyebrow(listName: "Picks", ownerName: nil, isOwn: false, count: 1), "Picks · 1 title")
    }

    func testAMovieSpotlightHasItsDetailsAndPlays() throws {
        let movie = try item("""
        {"Id":"m1","Name":"The Right Stuff","Type":"Movie","ProductionYear":1983,"RunTimeTicks":115800000000,
         "OfficialRating":"PG","Genres":["Drama","History","Adventure"],"Overview":"The Mercury 7.",
         "BackdropImageTags":["b"]}
        """)
        let spotlight = ListSpotlight(item: movie)
        XCTAssertEqual(spotlight.title, "The Right Stuff")
        XCTAssertEqual(spotlight.details, "1983 · 3h 13m · PG · Drama, History")
        XCTAssertEqual(spotlight.overview, "The Mercury 7.")
        XCTAssertEqual(spotlight.backdrop, .library(itemId: "m1", imageType: "Backdrop"))
        XCTAssertNil(spotlight.tag)
        XCTAssertEqual(spotlight.action, .play(movie))
    }

    /// A show's runtime is an episode's, so it is left out; with no backdrop of
    /// its own the poster stands in.
    func testAShowSpotlightLeavesOutRuntimeAndFallsBackToItsPoster() throws {
        let show = try item("""
        {"Id":"s1","Name":"The Borgias","Type":"Series","ProductionYear":2011,"RunTimeTicks":30000000000,
         "OfficialRating":"TV-MA","Genres":["Drama"]}
        """)
        let spotlight = ListSpotlight(item: show)
        XCTAssertEqual(spotlight.details, "2011 · TV-MA · Drama")
        XCTAssertNil(spotlight.overview)
        XCTAssertEqual(spotlight.backdrop, .library(itemId: "s1", imageType: "Primary"))
    }

    func testAMissingTitleSignedIntoRequestsOffersRequest() throws {
        let poster = "https://image.tmdb.org/t/p/w342/a.jpg"
        let tile = WatchlistTile(entry: entry("9", poster: poster, year: 2025, tmdb: "1233413"), libraryItem: nil,
                                 missingTag: .notOnServer)
        let spotlight = ListSpotlight(tile: tile, signedIntoRequests: true)
        XCTAssertEqual(spotlight.title, "Title 9")
        XCTAssertEqual(spotlight.details, "2025 · Movie")
        XCTAssertEqual(spotlight.tag, "Not on server")
        XCTAssertEqual(spotlight.backdrop, .remote(try XCTUnwrap(URL(string: poster))))
        XCTAssertEqual(spotlight.action, .request(SeerrTarget(kind: .movie, tmdbId: 1_233_413, title: "Title 9")))
        XCTAssertTrue(spotlight.isMissing)
    }

    func testAMissingTitleNotSignedIntoRequestsOffersSignIn() {
        let tile = WatchlistTile(entry: entry("9", kind: .series, year: 2017), libraryItem: nil, missingTag: .requested)
        let spotlight = ListSpotlight(tile: tile, signedIntoRequests: false)
        XCTAssertEqual(spotlight.details, "2017 · Show")
        XCTAssertEqual(spotlight.tag, "Requested")
        XCTAssertEqual(spotlight.action, .signInToRequests)
    }

    /// Requests can't look up a title without a TMDB number: nothing to offer.
    func testAMissingTitleRequestsCantLookUpHasNoAction() {
        let entry = WatchlistEntry(id: "x", kind: .movie, title: "Home Video", ids: WatchlistIds(imdb: "tt1"))
        let tile = WatchlistTile(entry: entry, libraryItem: nil, missingTag: .notOnServer)
        XCTAssertEqual(ListSpotlight(tile: tile, signedIntoRequests: true).action, .none)
    }

    func testAnOnServerTileIsTheLibraryItemsSpotlight() throws {
        let movie = try item("{\"Id\":\"lib9\",\"Name\":\"Heat\",\"Type\":\"Movie\",\"ProductionYear\":1995}")
        let tile = WatchlistTile(entry: entry("1", itemId: "lib9"), libraryItem: movie, missingTag: nil)
        XCTAssertEqual(ListSpotlight(tile: tile, signedIntoRequests: false), ListSpotlight(item: movie))
    }

    /// The Spotlight needs the overview, genres and runtime: list entries and
    /// the Watchlist's library items ask for them.
    func testListItemsAreFetchedWithWhatTheSpotlightShows() async throws {
        JellyfinRouteStub.routes["GET /Users/me/Items"] = (200, "{\"Items\":[]}")
        JellyfinRouteStub.routes["GET /Playlists/p1/Items"] = (200, "{\"Items\":[]}")
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "t", userId: "me")
        _ = try await client.getItemsForCards(itemIds: ["a"])
        _ = try await client.getPlaylistEntries(playlistId: "p1")
        let fieldLists = JellyfinRouteStub.recorded.compactMap { $0.query["Fields"] }
        XCTAssertEqual(fieldLists.count, 2)
        for fields in fieldLists {
            let names = Set(fields.split(separator: ",").map(String.init))
            XCTAssertTrue(names.isSuperset(of: ["Overview", "Genres", "RunTimeTicks", "OfficialRating", "ProductionYear"]),
                          fields)
        }
    }
}
