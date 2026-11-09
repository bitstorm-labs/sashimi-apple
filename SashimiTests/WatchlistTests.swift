import XCTest
@testable import Sashimi

final class WatchlistTests: XCTestCase {
    private let camelJSON = """
    {"plex":{"username":"chad","needsReconnect":false},"cardDismissed":true,"entries":[
     {"id":"a1","type":"Movie","title":"Heat","year":1995,"posterUrl":"https://image.tmdb.org/t/p/w500/h.jpg",
      "tmdbId":"949","tvdbId":null,"imdbId":"tt0113277","addedAt":"2026-11-09T10:00:00.123Z","itemId":"abc123"},
     {"id":"b2","type":"Series","title":"Severance","year":2022,"posterUrl":null,
      "tmdbId":"95396","tvdbId":"371980","imdbId":null,"addedAt":"2026-11-08T09:00:00Z","itemId":null}]}
    """

    private func pascal(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        func up(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return Dictionary(uniqueKeysWithValues: dict.map { key, val in
                    (key.prefix(1).uppercased() + key.dropFirst(), up(val))
                })
            }
            if let array = value as? [Any] { return array.map(up) }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: up(object))
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    private func decode(_ json: String) throws -> WatchlistResponse {
        try WatchlistJSON.decoder().decode(WatchlistResponse.self, from: Data(json.utf8))
    }

    private func item(_ type: ItemType, ids: [String: String]?, year: Int? = 2020) -> BaseItemDto {
        var dto = BaseItemDto(
            id: "x", name: "Title", type: type,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: year,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
        dto.providerIds = ids
        return dto
    }

    func testDecodesTheContractShapeInCamelCase() throws {
        let response = try decode(camelJSON)
        XCTAssertEqual(response.plex, PlexLink(username: "chad", needsReconnect: false))
        XCTAssertTrue(response.cardDismissed)
        XCTAssertEqual(response.entries.count, 2)
        let heat = response.entries[0]
        XCTAssertEqual(heat.id, "a1")
        XCTAssertEqual(heat.kind, .movie)
        XCTAssertEqual(heat.year, 1995)
        XCTAssertEqual(heat.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w500/h.jpg")
        XCTAssertEqual(heat.ids, WatchlistIds(tmdb: "949", tvdb: nil, imdb: "tt0113277"))
        XCTAssertEqual(heat.itemId, "abc123")
        XCTAssertNotNil(heat.addedAt)
        let sev = response.entries[1]
        XCTAssertEqual(sev.kind, .series)
        XCTAssertNil(sev.itemId)
        XCTAssertNil(sev.posterURL)
        XCTAssertNotNil(sev.addedAt)
    }

    func testDecodesTheSameShapeInPascalCase() throws {
        XCTAssertEqual(try decode(try pascal(camelJSON)), try decode(camelJSON))
    }

    func testAnEntryWithAnUnreadableDateStillDecodes() throws {
        let json = camelJSON.replacingOccurrences(of: "2026-11-08T09:00:00Z", with: "last tuesday")
        let response = try decode(json)
        XCTAssertEqual(response.entries.count, 2)
        XCTAssertNil(response.entries[1].addedAt)
        XCTAssertNotNil(response.entries[0].addedAt)
    }

    func testKindDecodesCaseInsensitively() throws {
        let json = camelJSON.replacingOccurrences(of: "\"Movie\"", with: "\"movie\"")
        XCTAssertEqual(try decode(json).entries[0].kind, .movie)
    }

    func testAddResponseDecodes() throws {
        let json = "{\"entry\":{\"id\":\"a\",\"type\":\"Movie\",\"title\":\"T\",\"tmdbId\":\"1\"},\"added\":false}"
        let response = try WatchlistJSON.decoder().decode(WatchlistAddResponse.self, from: Data(json.utf8))
        XCTAssertFalse(response.added)
        XCTAssertEqual(response.entry.ids.tmdb, "1")
    }

    func testIdsAgreeOnAnySharedIdAndImdbIgnoresCase() {
        XCTAssertTrue(WatchlistIds(tmdb: "1", tvdb: "9").agrees(with: WatchlistIds(tmdb: "1", tvdb: "8")))
        XCTAssertTrue(WatchlistIds(imdb: "TT123").agrees(with: WatchlistIds(imdb: "tt123")))
        XCTAssertTrue(WatchlistIds(tvdb: "5").agrees(with: WatchlistIds(tmdb: "2", tvdb: "5")))
    }

    func testDisjointIdsDoNotAgree() {
        XCTAssertFalse(WatchlistIds(tmdb: "1").agrees(with: WatchlistIds(tmdb: "2")))
        XCTAssertFalse(WatchlistIds(tmdb: "1").agrees(with: WatchlistIds(tvdb: "1")))
        XCTAssertFalse(WatchlistIds().agrees(with: WatchlistIds()))
    }

    func testProviderIdKeysAreReadCaseInsensitively() {
        let ids = WatchlistIds(providerIds: ["tmdb": "1", "IMDB": "tt2", "Tvdb": ""])
        XCTAssertEqual(ids.tmdb, "1")
        XCTAssertEqual(ids.imdb, "tt2")
        XCTAssertNil(ids.tvdb)
        XCTAssertTrue(WatchlistIds(providerIds: nil).isEmpty)
    }

    func testEpisodesAndItemsWithoutIdsAreNotWatchlistable() {
        XCTAssertNil(Watchlist.ids(for: item(.episode, ids: ["Tmdb": "1"])))
        XCTAssertNil(Watchlist.ids(for: item(.movie, ids: [:])))
        XCTAssertNil(Watchlist.ids(for: item(.video, ids: ["Tmdb": "1"])))
        XCTAssertNil(Watchlist.newEntry(for: item(.movie, ids: nil)))
        XCTAssertEqual(Watchlist.ids(for: item(.series, ids: ["Tvdb": "7"])), WatchlistIds(tvdb: "7"))
    }

    func testServerItemBecomesAnEntryWithoutAPoster() throws {
        let entry = try XCTUnwrap(Watchlist.newEntry(for: item(.movie, ids: ["Tmdb": "1", "Imdb": "tt1"], year: 1999)))
        XCTAssertEqual(entry, NewWatchlistEntry(type: .movie, title: "Title", year: 1999, posterUrl: nil,
                                                tmdbId: "1", tvdbId: nil, imdbId: "tt1"))
        XCTAssertEqual(Watchlist.kind(for: .series), .series)
        XCTAssertNil(Watchlist.kind(for: nil))
        XCTAssertNil(Watchlist.kind(for: .boxSet))
    }

    func testASeerrShowBecomesASeriesEntryWithItsTmdbIdAndPoster() throws {
        let target = SeerrTarget(kind: .tv, tmdbId: 95396, title: "Severance", posterPath: "/s.jpg")
        let entry = Watchlist.newEntry(for: target, year: 2022)
        XCTAssertEqual(entry.type, .series)
        XCTAssertEqual(entry.tmdbId, "95396")
        XCTAssertEqual(entry.title, "Severance")
        XCTAssertEqual(entry.year, 2022)
        XCTAssertTrue(try XCTUnwrap(entry.posterUrl).hasPrefix("https://image.tmdb.org/"))
        let movie = Watchlist.newEntry(for: SeerrTarget(kind: .movie, tmdbId: 1, title: "M"), year: nil)
        XCTAssertEqual(movie.type, .movie)
        XCTAssertNil(movie.posterUrl)
    }

    func testNewEntryEncodesCamelCaseAndOmitsNils() throws {
        let entry = NewWatchlistEntry(type: .movie, title: "Heat", year: nil, posterUrl: nil,
                                      tmdbId: "949", tvdbId: nil, imdbId: nil)
        let data = try WatchlistJSON.encoder().encode(entry)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(dict.keys), ["type", "title", "tmdbId"])
        XCTAssertEqual(dict["type"] as? String, "Movie")
    }

    func testContainsMatchesOnAnySharedId() {
        let entries = [WatchlistEntry(id: "a", kind: .movie, title: "Heat", ids: WatchlistIds(tmdb: "949"))]
        XCTAssertTrue(Watchlist.contains(entries, ids: WatchlistIds(tmdb: "949", imdb: "tt1")))
        XCTAssertFalse(Watchlist.contains(entries, ids: WatchlistIds(tmdb: "1")))
    }

    func testOnlyPendingAndComingReadAsRequested() {
        let table: [(SeerrBadge?, Watchlist.MissingTag)] = [
            (.request, .notOnServer), (.pending, .requested), (.coming, .requested),
            (.declined, .notOnServer), (.available, .notOnServer), (nil, .notOnServer)
        ]
        for (badge, expected) in table {
            XCTAssertEqual(Watchlist.missingTag(badge: badge), expected, "\(String(describing: badge))")
        }
        XCTAssertEqual(Watchlist.MissingTag.notOnServer.label, "Not on server")
        XCTAssertEqual(Watchlist.MissingTag.requested.label, "Requested")
    }

    func testAnEntryWithoutATmdbIdHasNoSeerrTarget() {
        let none = WatchlistEntry(id: "a", kind: .movie, title: "T", ids: WatchlistIds(imdb: "tt1"))
        let junk = WatchlistEntry(id: "b", kind: .movie, title: "T", ids: WatchlistIds(tmdb: "abc"))
        XCTAssertNil(Watchlist.seerrTarget(for: none))
        XCTAssertNil(Watchlist.seerrTarget(for: junk))
        let show = WatchlistEntry(id: "c", kind: .series, title: "S",
                                  posterURL: nil, ids: WatchlistIds(tmdb: "42"))
        XCTAssertEqual(Watchlist.seerrTarget(for: show), SeerrTarget(kind: .tv, tmdbId: 42, title: "S"))
    }

    func testSwitchQuestionNamesTheAccount() {
        XCTAssertEqual(WatchlistText.switchQuestion(newUsername: "bob"),
                       "Sync your Watchlist with Plex account bob instead?")
        XCTAssertEqual(WatchlistText.switchQuestion(newUsername: nil),
                       "Sync your Watchlist with this Plex account instead?")
    }
}
