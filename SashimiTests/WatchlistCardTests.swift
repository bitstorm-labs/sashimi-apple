import XCTest
@testable import Sashimi

/// The Watchlist card on the Lists page, and where each poster comes from.
@MainActor
final class WatchlistCardTests: XCTestCase {
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

    private func entry(_ id: String, itemId: String? = nil, poster: String? = nil) -> WatchlistEntry {
        WatchlistEntry(id: id, kind: .movie, title: "Title \(id)", posterURL: poster.flatMap(URL.init(string:)),
                       ids: WatchlistIds(tmdb: id), itemId: itemId)
    }

    private func list(plex: PlexLink? = nil, entries: [WatchlistEntry]) -> WatchlistResponse {
        WatchlistResponse(plex: plex, cardDismissed: false, entries: entries)
    }

    private func store() throws -> WatchlistStore {
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        return WatchlistStore(service: WatchlistService(client: client))
    }

    func testSubtitleIsTheSummary() {
        let card = WatchlistCardInfo(list(entries: [entry("1"), entry("2")]))
        XCTAssertEqual(card.subtitle, "Private · 2 titles")
    }

    func testSubtitleSaysSyncedWhenPlexIsLinked() {
        let card = WatchlistCardInfo(list(plex: PlexLink(username: "marge", needsReconnect: false), entries: [entry("1")]))
        XCTAssertEqual(card.subtitle, "Private · 1 title · Synced with Plex")
    }

    func testALinkThatNeedsReconnectingIsNotCalledSynced() {
        let card = WatchlistCardInfo(list(plex: PlexLink(username: "marge", needsReconnect: true), entries: [entry("1")]))
        XCTAssertEqual(card.subtitle, "Private · 1 title")
    }

    func testCoverIsTheFirstFourTitlesArtwork() throws {
        let poster = "https://image.tmdb.org/t/p/w342/a.jpg"
        let entries = [entry("1", itemId: "lib1", poster: poster), entry("2", poster: poster), entry("3"),
                       entry("4", itemId: "lib4"), entry("5", itemId: "lib5")]
        let card = WatchlistCardInfo(list(entries: entries))
        XCTAssertEqual(card.cover, [.library(itemId: "lib1"), .remote(try XCTUnwrap(URL(string: poster))), .none,
                                    .library(itemId: "lib4")])
    }

    func testAnOnServerTileUsesTheServersPoster() throws {
        let item = try JSONDecoder().decode(BaseItemDto.self, from: Data("{\"Id\":\"lib9\",\"Name\":\"Heat\",\"Type\":\"Movie\"}".utf8))
        let tile = WatchlistTile(entry: entry("1", itemId: "stale", poster: "https://image.tmdb.org/t/p/w342/a.jpg"),
                                 libraryItem: item, missingTag: nil)
        XCTAssertEqual(tile.artwork, .library(itemId: "lib9"))
    }

    func testAMissingTileUsesTheSavedPosterEvenWithAStaleItemId() throws {
        let poster = "https://image.tmdb.org/t/p/w342/a.jpg"
        let tile = WatchlistTile(entry: entry("1", itemId: "stale", poster: poster), libraryItem: nil, missingTag: .notOnServer)
        XCTAssertEqual(tile.artwork, .remote(try XCTUnwrap(URL(string: poster))))
    }

    func testTheStoreHasACardWithThePlugin() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, "{\"cardDismissed\":false,\"entries\":[]}")
        let store = try store()
        await store.refresh()
        XCTAssertEqual(store.card?.subtitle, "Private · 0 titles")
    }

    func testTheStoreHasNoCardWithoutThePlugin() async throws {
        let store = try store()
        await store.refresh()
        XCTAssertEqual(store.availability, .unavailable)
        XCTAssertNil(store.card)
    }
}
