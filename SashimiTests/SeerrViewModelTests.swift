import XCTest
@testable import Sashimi

/// The screens' state: search's request row, the request page and its
/// button, and Your requests. Every request and cancel goes to the stub.
@MainActor
final class SeerrViewModelTests: XCTestCase {
    private var credentials = InMemorySeerrCredentials()

    override func setUp() {
        super.setUp()
        SeerrStubServer.reset()
        SeerrClient.testURLProtocolClasses = [SeerrStubServer.self]
        credentials = InMemorySeerrCredentials()
    }

    override func tearDown() {
        SeerrClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func signedInSession(user: String = SeerrFixtures.user()) async -> SeerrSession {
        let session = SeerrSession(defaults: SeerrFixtures.defaults(), credentials: credentials, pollInterval: .zero)
        _ = session.setServerAddress(SeerrFixtures.server.absoluteString)
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: user, headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await session.signInLocal(email: "mom@example.com", password: "pw")
        SeerrStubServer.reset()
        return session
    }

    // MARK: Search row

    func testWithoutAnAccountSearchNeverAsksSeerr() async {
        let session = SeerrSession(defaults: SeerrFixtures.defaults(), credentials: credentials, pollInterval: .zero)
        let model = SeerrSearchModel(session: session)

        await model.search(query: "dune", library: [])

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isVisible)
        XCTAssertTrue(SeerrStubServer.requests.isEmpty)
    }

    func testSearchRowCarriesPillsAndSkipsTheLibrary() async {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/search", body: """
        {"page":1,"totalPages":1,"results":[
          {"id":90228,"mediaType":"tv","name":"Dune: Prophecy"},
          {"id":841,"mediaType":"movie","title":"Dune","releaseDate":"1984-12-14","mediaInfo":{"status":2}},
          {"id":438631,"mediaType":"movie","title":"Dune","mediaInfo":{"status":5}}
        ]}
        """)
        let model = SeerrSearchModel(session: session)

        await model.search(query: "dune", library: [])

        XCTAssertEqual(model.items.map(\.result.tmdbId), [90228, 841])
        XCTAssertEqual(model.items.map(\.badge), [.request, .pending])
        XCTAssertTrue(model.isVisible)
    }

    func testAnExpiredSessionDuringSearchSignsOut() async {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/search", status: 401, body: "{}")
        SeerrStubServer.on("GET", "/api/v1/auth/me", status: 401, body: "{}")
        let model = SeerrSearchModel(session: session)

        await model.search(query: "dune", library: [])

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(session.state, .expired)
    }

    // MARK: Request page

    private let movieJSON = "{\"id\":1,\"title\":\"Jodorowsky's Dune\",\"releaseDate\":\"2013-05-01\"}"
    private let pendingMovieJSON = "{\"id\":1,\"title\":\"Jodorowsky's Dune\",\"mediaInfo\":{\"status\":2,\"requests\":[{\"id\":11,\"status\":1,\"requestedBy\":{\"id\":7}}]}}"

    func testAMovieRequestsInOnePressAndTheButtonBecomesAStatusLine() async {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: movieJSON)
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: pendingMovieJSON)
        SeerrStubServer.on("POST", "/api/v1/request", status: 201, body: "{\"id\":11,\"status\":1}")
        let model = SeerrDetailModel(target: SeerrTarget(kind: .movie, tmdbId: 1, title: "Jodorowsky's Dune"), session: session, libraryLookup: { _, _, _ in nil })

        await model.load()
        XCTAssertEqual(model.action, .request)

        await model.requestMovie()

        XCTAssertEqual(SeerrStubServer.requests("POST", "/api/v1/request").count, 1)
        XCTAssertEqual(model.action, .status("Requested · waiting for approval"))
    }

    func testAShowOpensThePickerAndSendsTheTickedSeasons() async throws {
        let session = await signedInSession()
        let show = """
        {"id":90228,"name":"Dune: Prophecy","seasons":[{"seasonNumber":1,"episodeCount":6,"airDate":"2024-11-17"},{"seasonNumber":2,"episodeCount":0,"airDate":null}]}
        """
        SeerrStubServer.on("GET", "/api/v1/tv/90228", body: show)
        SeerrStubServer.on("POST", "/api/v1/request", status: 201, body: "{\"id\":12,\"status\":1}")
        let model = SeerrDetailModel(target: SeerrTarget(kind: .tv, tmdbId: 90228, title: "Dune: Prophecy"), session: session, libraryLookup: { _, _, _ in nil })

        await model.load()
        XCTAssertEqual(model.action, .chooseSeasons)
        let plan = try XCTUnwrap(model.seasonPlan())
        XCTAssertEqual(plan.buttonTitle, "Request 1 season")

        await model.requestSeasons(plan)

        let body = try XCTUnwrap(SeerrStubServer.requests("POST", "/api/v1/request").first?.json)
        XCTAssertEqual(body["seasons"] as? [Int], [1])
    }

    func testComingAndAvailableStates() async {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: "{\"id\":1,\"title\":\"A\",\"mediaInfo\":{\"status\":3}}")
        let coming = SeerrDetailModel(target: SeerrTarget(kind: .movie, tmdbId: 1, title: "A"), session: session, libraryLookup: { _, _, _ in nil })
        await coming.load()
        XCTAssertEqual(coming.action, .status("Coming soon"))

        SeerrStubServer.reset()
        SeerrStubServer.on("GET", "/api/v1/movie/2", body: "{\"id\":2,\"title\":\"B\",\"mediaInfo\":{\"status\":5}}")
        let arrived = try? JSONDecoder().decode(BaseItemDto.self, from: Data("{\"Id\":\"jf-2\",\"Name\":\"B\",\"Type\":\"Movie\"}".utf8))
        var asked: (Int, SeerrMediaKind)?
        let available = SeerrDetailModel(target: SeerrTarget(kind: .movie, tmdbId: 2, title: "B"), session: session) { id, kind, _ in
            asked = (id, kind)
            return arrived
        }
        await available.load()
        XCTAssertEqual(available.libraryItem?.id, "jf-2", "the page turns into the library page")
        XCTAssertEqual(asked?.0, 2)
    }

    func testAFailedRequestKeepsTheButtonAndSaysWhy() async {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: movieJSON)
        SeerrStubServer.on("POST", "/api/v1/request", status: 403, body: "{\"message\":\"You do not have permission to request.\"}")
        SeerrStubServer.on("GET", "/api/v1/auth/me", body: SeerrFixtures.user())
        let model = SeerrDetailModel(target: SeerrTarget(kind: .movie, tmdbId: 1, title: "A"), session: session, libraryLookup: { _, _, _ in nil })

        await model.load()
        await model.requestMovie()

        XCTAssertEqual(model.action, .request)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(session.isActive)
    }

    // MARK: Your requests

    private let requestsJSON = """
    {"pageInfo":{"page":1,"pages":1,"results":2},"results":[
      {"id":4,"status":1,"type":"movie","createdAt":"2026-11-06T10:00:00.000Z","media":{"tmdbId":1,"mediaType":"movie","status":2},"requestedBy":{"id":7}},
      {"id":5,"status":2,"type":"movie","createdAt":"2026-11-01T10:00:00.000Z","media":{"tmdbId":2,"mediaType":"movie","status":3},"requestedBy":{"id":7}}
    ]}
    """

    func testYourRequestsLoadsTheUsersRequestsWithTitles() async {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/request", body: requestsJSON)
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: "{\"id\":1,\"title\":\"First\",\"posterPath\":\"/1.jpg\"}")
        SeerrStubServer.on("GET", "/api/v1/movie/2", body: "{\"id\":2,\"title\":\"Second\"}")
        let model = SeerrRequestsModel(session: session)

        await model.load()

        XCTAssertEqual(model.rows.map(\.title), ["First", "Second"])
        XCTAssertEqual(model.rows.map(\.state), [.pending, .coming(progress: nil)])
        XCTAssertTrue(SeerrStubServer.requests("GET", "/api/v1/request").first?.url.query?.contains("requestedBy=7") == true)
        XCTAssertEqual(model.homeRows.count, 2)
    }

    /// An administrator's Home row is everyone's requests (#855), one poster
    /// per title even when several people asked for it.
    func testHomeRequestsRowIsEveryonesForThoseWhoMaySeeThem() async {
        let session = await signedInSession(user: "{\"id\":1,\"displayName\":\"owner\",\"permissions\":2}")
        SeerrStubServer.on("GET", "/api/v1/request", body: """
        {"pageInfo":{"page":1,"pages":1,"results":3},"results":[
          {"id":9,"status":2,"type":"movie","createdAt":"2026-11-06T10:00:00.000Z","media":{"tmdbId":1,"mediaType":"movie","status":3},"requestedBy":{"id":41,"displayName":"Kurt"}},
          {"id":8,"status":2,"type":"movie","createdAt":"2026-11-05T10:00:00.000Z","media":{"tmdbId":1,"mediaType":"movie","status":3},"requestedBy":{"id":18}},
          {"id":7,"status":1,"type":"movie","createdAt":"2026-11-04T10:00:00.000Z","media":{"tmdbId":2,"mediaType":"movie","status":2},"requestedBy":{"id":6}}
        ]}
        """)
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: "{\"id\":1,\"title\":\"First\"}")
        SeerrStubServer.on("GET", "/api/v1/movie/2", body: "{\"id\":2,\"title\":\"Second\"}")
        let model = SeerrRequestsModel(session: session)

        await model.load()

        let query = SeerrStubServer.requests("GET", "/api/v1/request").first?.url.query ?? ""
        XCTAssertFalse(query.contains("requestedBy"), "everyone's, not just mine: \(query)")
        XCTAssertEqual(model.rows.map(\.id), [9, 7], "the newest request per title")
        XCTAssertEqual(model.title, "Recent Requests")
        XCTAssertEqual(model.rows.first.flatMap(model.requester(of:)), "Kurt", "who asked, under the title")
    }

    func testARequestOnlyAccountKeepsYourRequests() async {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/request", body: requestsJSON)
        let model = SeerrRequestsModel(session: session)

        await model.load()

        XCTAssertTrue(SeerrStubServer.requests("GET", "/api/v1/request").first?.url.query?.contains("requestedBy=7") == true)
        XCTAssertEqual(model.title, "Your Requests")
        XCTAssertNil(model.rows.first.flatMap(model.requester(of:)), "always the person themselves, so no name")
    }

    // MARK: Request missing seasons (library show's More menu)

    private func libraryShow(tmdb: String?) throws -> BaseItemDto {
        let ids = tmdb.map { ",\"ProviderIds\":{\"Tmdb\":\"\($0)\"}" } ?? ""
        return try JSONDecoder().decode(BaseItemDto.self, from: Data("{\"Id\":\"s1\",\"Name\":\"Love Is Blind\",\"Type\":\"Series\"\(ids)}".utf8))
    }

    func testALibraryShowMissingSeasonsOffersToRequestThem() async throws {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/tv/77", body: """
        {"id":77,"name":"Love Is Blind","seasons":[{"seasonNumber":1,"episodeCount":10,"airDate":"2020-02-13"},{"seasonNumber":2,"episodeCount":10,"airDate":"2022-02-13"}],
         "mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5}]}}
        """)

        let target = await SeerrDetailModel.missingSeasonsTarget(for: try libraryShow(tmdb: "77"), session: session)

        XCTAssertEqual(target?.tmdbId, 77)
        XCTAssertEqual(target?.kind, .tv)
    }

    func testAShowWithEverySeasonOnTheServerOffersNothing() async throws {
        let session = await signedInSession()
        SeerrStubServer.on("GET", "/api/v1/tv/77", body: """
        {"id":77,"name":"Love Is Blind","seasons":[{"seasonNumber":1,"episodeCount":10,"airDate":"2020-02-13"}],
         "mediaInfo":{"status":5,"seasons":[{"seasonNumber":1,"status":5}]}}
        """)

        let target = await SeerrDetailModel.missingSeasonsTarget(for: try libraryShow(tmdb: "77"), session: session)

        XCTAssertNil(target)
    }

    func testMissingSeasonsNeedsAnAccountAndATmdbId() async throws {
        let signedOut = SeerrSession(defaults: SeerrFixtures.defaults(), credentials: credentials, pollInterval: .zero)
        let none = await SeerrDetailModel.missingSeasonsTarget(for: try libraryShow(tmdb: "77"), session: signedOut)
        XCTAssertNil(none)

        let session = await signedInSession()
        let untagged = await SeerrDetailModel.missingSeasonsTarget(for: try libraryShow(tmdb: nil), session: session)
        XCTAssertNil(untagged)
        XCTAssertTrue(SeerrStubServer.requests.isEmpty)
    }

    func testSignedOutHasNoRequests() async {
        let session = SeerrSession(defaults: SeerrFixtures.defaults(), credentials: credentials, pollInterval: .zero)
        let model = SeerrRequestsModel(session: session)

        await model.load()

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(SeerrStubServer.requests.isEmpty)
    }
}
