import XCTest
@testable import Sashimi

/// The Seerr API client, against a stubbed server: what each call sends and
/// how it reads the answers. No request ever leaves the process.
final class SeerrClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SeerrStubServer.reset()
        SeerrClient.testURLProtocolClasses = [SeerrStubServer.self]
    }

    override func tearDown() {
        SeerrClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client(cookie: String? = SeerrFixtures.sessionCookie) -> SeerrClient {
        SeerrClient(baseURL: SeerrFixtures.server, cookie: cookie)
    }

    // MARK: Auth

    func testPlexSignInPostsTheTokenAndKeepsOnlyTheSessionCookie() async throws {
        SeerrStubServer.on("POST", "/api/v1/auth/plex", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])

        let session = try await client(cookie: nil).signInWithPlex(authToken: "plex-token")

        XCTAssertEqual(session.user.id, 7)
        XCTAssertEqual(session.user.name, "mom")
        XCTAssertEqual(session.cookie, SeerrFixtures.sessionCookie, "name=value only, no attributes")
        let sent = try XCTUnwrap(SeerrStubServer.requests("POST", "/api/v1/auth/plex").first)
        XCTAssertEqual(sent.json?["authToken"] as? String, "plex-token")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
    }

    func testLocalSignInPostsEmailAndPassword() async throws {
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(id: 3, name: "guest"), headers: ["Set-Cookie": SeerrFixtures.setCookie])

        let session = try await client(cookie: nil).signInLocal(email: "guest@example.com", password: "pw")

        XCTAssertEqual(session.user.id, 3)
        let sent = try XCTUnwrap(SeerrStubServer.requests("POST", "/api/v1/auth/local").first)
        XCTAssertEqual(sent.json?["email"] as? String, "guest@example.com")
        XCTAssertEqual(sent.json?["password"] as? String, "pw")
    }

    func testAWrongPasswordIsInvalidCredentialsNotAnExpiredSession() async {
        SeerrStubServer.on("POST", "/api/v1/auth/local", status: 403, body: "{\"message\":\"Access denied.\"}")

        do {
            _ = try await client(cookie: nil).signInLocal(email: "guest@example.com", password: "nope")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SeerrError, .invalidCredentials)
        }
    }

    func testASignInWithoutASessionCookieFails() async {
        SeerrStubServer.on("POST", "/api/v1/auth/plex", body: SeerrFixtures.user())

        do {
            _ = try await client(cookie: nil).signInWithPlex(authToken: "plex-token")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SeerrError, .noSession)
        }
    }

    func testEveryCallCarriesTheSessionCookie() async throws {
        SeerrStubServer.on("GET", "/api/v1/auth/me", body: SeerrFixtures.user())

        _ = try await client().currentUser()

        XCTAssertEqual(SeerrStubServer.requests.first?.headers["Cookie"], SeerrFixtures.sessionCookie)
    }

    func testA401OrA403IsUnauthorized() async {
        for status in [401, 403] {
            SeerrStubServer.reset()
            SeerrStubServer.on("GET", "/api/v1/auth/me", status: status, body: "{}")
            do {
                _ = try await client().currentUser()
                XCTFail("expected a failure for \(status)")
            } catch {
                XCTAssertEqual(error as? SeerrError, .unauthorized, "status \(status)")
            }
        }
    }

    // MARK: Search

    func testSearchEncodesTheQueryStrictly() {
        XCTAssertEqual(SeerrClient.encodeQuery("dune: part two"), "dune%3A%20part%20two")
        XCTAssertEqual(SeerrClient.encodeQuery("tom & jerry!"), "tom%20%26%20jerry%21")
        XCTAssertEqual(SeerrClient.encodeQuery("amélie"), "am%C3%A9lie")
        XCTAssertEqual(SeerrClient.encodeQuery("a+b'(c)*"), "a%2Bb%27%28c%29%2A")
    }

    func testSearchSendsThePercentEncodedQueryAndDropsPeople() async throws {
        SeerrStubServer.on("GET", "/api/v1/search", body: """
        {"page":1,"totalPages":1,"totalResults":3,"results":[
          {"id":438631,"mediaType":"movie","title":"Dune","releaseDate":"2021-09-15","posterPath":"/d.jpg","mediaInfo":{"status":5}},
          {"id":90228,"mediaType":"tv","name":"Dune: Prophecy","firstAirDate":"2024-11-17"},
          {"id":1,"mediaType":"person","name":"Denis Villeneuve","profilePath":"/p.jpg"}
        ]}
        """)

        let page = try await client().search(query: "dune: prophecy")

        let sent = try XCTUnwrap(SeerrStubServer.requests.first)
        XCTAssertEqual(sent.url.query, "query=dune%3A%20prophecy&page=1")
        XCTAssertEqual(page.results.map(\.id), ["movie-438631", "tv-90228"])
        XCTAssertEqual(page.results[1].title, "Dune: Prophecy")
        XCTAssertEqual(page.results[1].year, 2024)
        XCTAssertEqual(page.results[0].mediaInfo?.mediaStatus, .available)
    }

    // MARK: Details

    func testTvDetailsDecodeSeasonsStatusRatingAndTrailer() async throws {
        SeerrStubServer.on("GET", "/api/v1/tv/90228", body: """
        {"id":90228,"name":"Dune: Prophecy","firstAirDate":"2024-11-17","status":"Returning Series",
         "overview":"Ten thousand years…","genres":[{"id":1,"name":"Sci-Fi"},{"id":2,"name":"Drama"}],
         "contentRatings":{"results":[{"iso_3166_1":"GB","rating":"15"},{"iso_3166_1":"US","rating":"TV-MA"}]},
         "relatedVideos":[{"key":"clip1","site":"YouTube","type":"Clip"},{"key":"trail1","site":"YouTube","type":"Trailer"}],
         "seasons":[{"seasonNumber":0,"episodeCount":2},{"seasonNumber":1,"episodeCount":6,"airDate":"2024-11-17"}],
         "credits":{"cast":[{"id":5,"name":"Emily Watson","character":"Valya"}]},
         "mediaInfo":{"status":3,"seasons":[{"seasonNumber":1,"status":3}]}}
        """)

        let details = try await client().details(kind: .tv, tmdbId: 90228)

        XCTAssertEqual(details.kind, .tv)
        XCTAssertEqual(details.title, "Dune: Prophecy")
        XCTAssertEqual(details.contentRating, "TV-MA")
        XCTAssertEqual(details.trailerKey, "trail1")
        XCTAssertEqual(details.seriesStatus, .continuing)
        XCTAssertEqual(details.genres.map(\.name), ["Sci-Fi", "Drama"])
        XCTAssertEqual(details.seasons.map(\.seasonNumber), [0, 1])
        XCTAssertEqual(details.credits?.cast?.first?.name, "Emily Watson")
        XCTAssertEqual(details.mediaInfo?.mediaStatus, .processing)
    }

    func testMovieDetailsReadTheUSCertification() async throws {
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: """
        {"id":1,"title":"Jodorowsky's Dune","releaseDate":"2013-05-01",
         "releases":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"PG-13"}]}]}}
        """)

        let details = try await client().details(kind: .movie, tmdbId: 1)

        XCTAssertEqual(details.kind, .movie)
        XCTAssertEqual(details.contentRating, "PG-13")
        XCTAssertNil(details.seriesStatus)
        XCTAssertEqual(details.year, 2013)
    }

    // MARK: Requests

    func testAMovieRequestSendsTypeAndTmdbId() async throws {
        SeerrStubServer.on("POST", "/api/v1/request", status: 201, body: "{\"id\":11,\"status\":1}")

        let request = try await client().requestMovie(tmdbId: 1)

        XCTAssertEqual(request.id, 11)
        let body = try XCTUnwrap(SeerrStubServer.requests("POST", "/api/v1/request").first?.json)
        XCTAssertEqual(body["mediaType"] as? String, "movie")
        XCTAssertEqual(body["mediaId"] as? Int, 1)
        XCTAssertNil(body["seasons"])
        XCTAssertNil(body["is4k"], "no 4K option")
    }

    func testAShowRequestSendsSortedSeasonsAndNeverSpecials() async throws {
        SeerrStubServer.on("POST", "/api/v1/request", status: 201, body: "{\"id\":12,\"status\":1}")

        _ = try await client().requestShow(tmdbId: 90228, seasons: [11, 0, 10])

        let body = try XCTUnwrap(SeerrStubServer.requests("POST", "/api/v1/request").first?.json)
        XCTAssertEqual(body["mediaType"] as? String, "tv")
        XCTAssertEqual(body["mediaId"] as? Int, 90228)
        XCTAssertEqual(body["seasons"] as? [Int], [10, 11])
    }

    func testAShowRequestWithNoSeasonsLeftIsRefusedWithoutCallingTheServer() async {
        do {
            _ = try await client().requestShow(tmdbId: 90228, seasons: [0])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SeerrError, .nothingToRequest)
        }
        XCTAssertTrue(SeerrStubServer.requests.isEmpty)
    }

    func testMyRequestsAsksForTheUsersOwnNewestFirst() async throws {
        SeerrStubServer.on("GET", "/api/v1/request", body: """
        {"pageInfo":{"pages":1,"page":1,"results":1},"results":[
          {"id":4,"status":2,"type":"movie","createdAt":"2026-11-03T10:00:00.000Z",
           "media":{"tmdbId":1,"mediaType":"movie","status":3,"downloadStatus":[{"size":100,"sizeLeft":38}]},
           "requestedBy":{"id":7}}
        ]}
        """)

        let requests = try await client().requests(requestedBy: 7)

        let query = try XCTUnwrap(SeerrStubServer.requests.first?.url.query)
        XCTAssertTrue(query.contains("requestedBy=7"))
        XCTAssertTrue(query.contains("take=50"))
        XCTAssertTrue(query.contains("sort=added"))
        XCTAssertEqual(requests.first?.media?.downloadStatus?.first?.sizeLeft, 38)
    }

    func testCancelDeletesThatRequest() async throws {
        SeerrStubServer.on("DELETE", "/api/v1/request/4", status: 204, body: "")

        try await client().cancelRequest(id: 4)

        XCTAssertEqual(SeerrStubServer.requests("DELETE", "/api/v1/request/4").count, 1)
    }

    func testAServerErrorCarriesItsMessage() async {
        SeerrStubServer.on("POST", "/api/v1/request", status: 409, body: "{\"message\":\"Request for this media already exists.\"}")

        do {
            _ = try await client().requestMovie(tmdbId: 1)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SeerrError, .server(status: 409, message: "Request for this media already exists."))
        }
    }

    // MARK: Plex PIN

    func testPlexPinIsCreatedWithTheAppsIdentity() async throws {
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")

        let pin = try await PlexPinClient(clientIdentifier: "install-uuid").createPin(strong: false)

        XCTAssertEqual(pin, PlexPin(id: 42, code: "K7QF"))
        let sent = try XCTUnwrap(SeerrStubServer.requests.first)
        XCTAssertEqual(sent.url.host, "plex.tv")
        XCTAssertEqual(sent.url.query, "strong=false")
        XCTAssertEqual(sent.headers["X-Plex-Product"], "Sashimi")
        XCTAssertEqual(sent.headers["X-Plex-Client-Identifier"], "install-uuid")
        XCTAssertEqual(sent.headers["Accept"], "application/json")
    }

    func testPlexPinPollReturnsTheTokenOnceLinked() async throws {
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":null}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":\"plex-token\"}")
        let plex = PlexPinClient(clientIdentifier: "install-uuid")

        let first = try await plex.checkPin(id: 42)
        let second = try await plex.checkPin(id: 42)

        XCTAssertNil(first.authToken)
        XCTAssertEqual(second.authToken, "plex-token")
    }

    func testPlexWebSignInURLCarriesClientCodeAndProduct() throws {
        let url = PlexPinClient.webSignInURL(clientIdentifier: "install-uuid", code: "abc123", forwardURL: "sashimi://plex-auth")
        let string = url.absoluteString

        XCTAssertTrue(string.hasPrefix("https://app.plex.tv/auth/#!?"))
        XCTAssertTrue(string.contains("clientID=install-uuid"))
        XCTAssertTrue(string.contains("code=abc123"))
        XCTAssertTrue(string.contains("context%5Bdevice%5D%5Bproduct%5D=Sashimi"))
        XCTAssertTrue(string.contains("forwardUrl=sashimi%3A%2F%2Fplex-auth"))
    }
}
