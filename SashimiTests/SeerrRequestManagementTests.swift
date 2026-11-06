import XCTest
@testable import Sashimi

/// The Requests page (#845): permissions, the request list with its filter,
/// scope, paging and actions, Discover's rows, and the quota line. Every
/// approve, decline, cancel and delete goes to the stub, never to a server.
@MainActor
final class SeerrRequestManagementTests: XCTestCase {
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

    /// Seerr's `/auth/me` for user `id` with `permissions`.
    private func userJSON(id: Int, permissions: Int) -> String {
        "{\"id\":\(id),\"displayName\":\"user\(id)\",\"permissions\":\(permissions),\"avatar\":\"/avatarproxy/\(id)\"}"
    }

    private func session(id: Int = 45, permissions: Int = 32) async -> SeerrSession {
        let session = SeerrSession(defaults: SeerrFixtures.defaults(), credentials: credentials, pollInterval: .zero)
        _ = session.setServerAddress(SeerrFixtures.server.absoluteString)
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: userJSON(id: id, permissions: permissions),
                           headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await session.signInLocal(email: "test@example.com", password: "pw")
        SeerrStubServer.reset()
        return session
    }

    private func request(id: Int, status: Int, by user: Int, tmdbId: Int = 100, mediaStatus: Int = 2) -> String {
        """
        {"id":\(id),"status":\(status),"type":"movie","createdAt":"2026-11-01T10:00:00.000Z",
         "media":{"tmdbId":\(tmdbId),"mediaType":"movie","status":\(mediaStatus)},
         "requestedBy":{"id":\(user),"displayName":"user\(user)","avatar":"https://plex.tv/users/\(user)/avatar"}}
        """
    }

    private func page(_ requests: [String], total: Int? = nil) -> String {
        "{\"pageInfo\":{\"pages\":1,\"pageSize\":20,\"results\":\(total ?? requests.count),\"page\":1},\"results\":[\(requests.joined(separator: ","))]}"
    }

    private func query(_ recorded: SeerrStubServer.Recorded) -> [String: String] {
        let items = URLComponents(url: recorded.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Permissions

    func testPermissionBitsFollowSeerr() {
        let requestOnly = SeerrPermissions(rawValue: 32)
        XCTAssertFalse(requestOnly.canViewAllRequests)
        XCTAssertFalse(requestOnly.canManageRequests)

        let admin = SeerrPermissions(rawValue: 2)
        XCTAssertTrue(admin.canViewAllRequests)
        XCTAssertTrue(admin.canManageRequests)

        let manager = SeerrPermissions(rawValue: 16 | 32)
        XCTAssertTrue(manager.canViewAllRequests)
        XCTAssertTrue(manager.canManageRequests)

        let viewer = SeerrPermissions(rawValue: 16_384 | 32)
        XCTAssertTrue(viewer.canViewAllRequests)
        XCTAssertFalse(viewer.canManageRequests, "REQUEST_VIEW sees everyone's but can't approve")
    }

    func testSignInKeepsThePermissionsForAnOfflineRestore() async {
        let defaults = SeerrFixtures.defaults()
        let session = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)
        _ = session.setServerAddress(SeerrFixtures.server.absoluteString)
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: userJSON(id: 1, permissions: 2), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await session.signInLocal(email: "a@example.com", password: "pw")
        XCTAssertTrue(session.permissions.canManageRequests)

        SeerrStubServer.reset()
        SeerrStubServer.on("GET", "/api/v1/auth/me", status: 500, body: "{}")
        let relaunched = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)
        await relaunched.restore()
        XCTAssertEqual(relaunched.state.user?.permissions, 2)
        XCTAssertTrue(relaunched.permissions.canManageRequests)
    }

    func testRequesterNameAndAvatarResolveAgainstTheServer() throws {
        let user = try JSONDecoder().decode(SeerrRequestUser.self, from: Data(userJSON(id: 9, permissions: 32).utf8))
        XCTAssertEqual(user.name, "user9")
        XCTAssertEqual(user.avatarURL(server: SeerrFixtures.server)?.absoluteString, "https://seerr.test/avatarproxy/9")
        let plex = SeerrRequestUser(id: 3, avatar: "https://plex.tv/users/3/avatar")
        XCTAssertEqual(plex.avatarURL(server: SeerrFixtures.server)?.absoluteString, "https://plex.tv/users/3/avatar")
        XCTAssertEqual(plex.name, "User 3")
    }

    // MARK: Request list: a REQUEST-only account (sashimi-test)

    func testARequestOnlyAccountOnlyEverAsksForItsOwnRequests() async throws {
        let session = await session(id: 45, permissions: 32)
        SeerrStubServer.on("GET", "/api/v1/request", body: page([request(id: 1, status: 1, by: 45)]))
        let model = SeerrRequestListModel(session: session)
        model.scope = .everyone

        await model.reload()

        XCTAssertFalse(model.canChooseScope)
        XCTAssertEqual(model.effectiveScope, .mine)
        XCTAssertFalse(model.showsRequester)
        let sent = try XCTUnwrap(SeerrStubServer.requests("GET", "/api/v1/request").first)
        XCTAssertEqual(query(sent)["requestedBy"], "45")
        XCTAssertEqual(query(sent)["filter"], "all")
        XCTAssertTrue(SeerrStubServer.requests("GET", "/api/v1/request/count").isEmpty, "the count is everyone's")
        XCTAssertNil(model.count)
    }

    func testARequesterCanCancelOnlyTheirOwnPendingRequest() async throws {
        let session = await session(id: 45, permissions: 32)
        SeerrStubServer.on("GET", "/api/v1/request", body: page([
            request(id: 1, status: 1, by: 45),
            request(id: 2, status: 2, by: 45, tmdbId: 101)
        ]))
        let model = SeerrRequestListModel(session: session)
        await model.reload()
        let pending = try XCTUnwrap(model.rows.first { $0.id == 1 })
        let approved = try XCTUnwrap(model.rows.first { $0.id == 2 })

        XCTAssertEqual(model.actions(for: pending), [.cancel])
        XCTAssertEqual(model.actions(for: approved), [])

        await model.perform(.approve, on: pending)
        await model.perform(.delete, on: approved)
        XCTAssertTrue(SeerrStubServer.requests.filter { $0.method != "GET" }.isEmpty, "nothing the account lacks is sent")

        SeerrStubServer.on("DELETE", "/api/v1/request/1", status: 204, body: "")
        await model.perform(.cancel, on: pending)
        XCTAssertEqual(SeerrStubServer.requests("DELETE", "/api/v1/request/1").count, 1)
        XCTAssertFalse(model.rows.contains { $0.id == 1 })
    }

    // MARK: Request list: an administrator

    func testAnAdministratorSeesEveryoneAndTheCount() async throws {
        let session = await session(id: 1, permissions: 2)
        SeerrStubServer.on("GET", "/api/v1/request", body: page([request(id: 5, status: 1, by: 7)]))
        SeerrStubServer.on("GET", "/api/v1/request/count", body: "{\"total\":493,\"pending\":0,\"processing\":78,\"available\":56}")
        let model = SeerrRequestListModel(session: session)
        model.scope = .everyone
        model.filter = .pending

        await model.reload()

        XCTAssertTrue(model.canChooseScope)
        XCTAssertTrue(model.showsRequester)
        let sent = try XCTUnwrap(SeerrStubServer.requests("GET", "/api/v1/request").first)
        XCTAssertNil(query(sent)["requestedBy"])
        XCTAssertEqual(query(sent)["filter"], "pending")
        XCTAssertEqual(query(sent)["sort"], "added")
        XCTAssertEqual(model.count?.summary, "493 requests \u{00B7} 0 pending \u{00B7} 78 processing \u{00B7} 56 available")
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(row.requesterName, "user7")
        XCTAssertEqual(model.actions(for: row), [.approve, .decline, .delete])
    }

    func testApprovingPostsAndThePendingFilterDropsTheRow() async throws {
        let session = await session(id: 1, permissions: 16 | 32)
        SeerrStubServer.on("GET", "/api/v1/request", body: page([request(id: 5, status: 1, by: 7)]))
        SeerrStubServer.on("POST", "/api/v1/request/5/approve", body: "{\"id\":5,\"status\":2}")
        let model = SeerrRequestListModel(session: session)
        model.filter = .pending
        await model.reload()

        await model.perform(.approve, on: try XCTUnwrap(model.rows.first))

        XCTAssertEqual(SeerrStubServer.requests("POST", "/api/v1/request/5/approve").count, 1)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(session.requestsRevision, 1)
    }

    func testDecliningUnderAllKeepsTheRowAsDeclined() async throws {
        let session = await session(id: 1, permissions: 2)
        SeerrStubServer.on("GET", "/api/v1/request", body: page([request(id: 5, status: 1, by: 7)]))
        SeerrStubServer.on("POST", "/api/v1/request/5/decline", body: "{\"id\":5,\"status\":3}")
        let model = SeerrRequestListModel(session: session)
        await model.reload()

        await model.perform(.decline, on: try XCTUnwrap(model.rows.first))

        XCTAssertEqual(SeerrStubServer.requests("POST", "/api/v1/request/5/decline").count, 1)
        XCTAssertEqual(model.rows.first?.requestStatus.label, "Declined")
        XCTAssertEqual(model.actions(for: try XCTUnwrap(model.rows.first)), [.delete])
    }

    func testAFailedActionSaysWhy() async throws {
        let session = await session(id: 1, permissions: 2)
        SeerrStubServer.on("GET", "/api/v1/request", body: page([request(id: 5, status: 1, by: 7)]))
        SeerrStubServer.on("POST", "/api/v1/request/5/approve", status: 409,
                           body: "{\"message\":\"Only pending requests can be approved or declined.\"}")
        let model = SeerrRequestListModel(session: session)
        await model.reload()

        await model.perform(.approve, on: try XCTUnwrap(model.rows.first))

        XCTAssertEqual(model.errorMessage, "Only pending requests can be approved or declined.")
        XCTAssertEqual(model.rows.first?.requestStatus.label, "Pending")
    }

    func testTheNextPageLoadsNearTheEnd() async throws {
        let session = await session(id: 45, permissions: 32)
        let first = (1...3).map { request(id: $0, status: 2, by: 45, tmdbId: 100 + $0) }
        let second = [request(id: 4, status: 2, by: 45, tmdbId: 104)]
        SeerrStubServer.on("GET", "/api/v1/request", body: page(first, total: 4))
        SeerrStubServer.on("GET", "/api/v1/request", body: page(second, total: 4))
        let model = SeerrRequestListModel(session: session, pageSize: 3)
        await model.reload()
        XCTAssertTrue(model.canLoadMore)

        await model.loadMoreIfNeeded(after: try XCTUnwrap(model.rows.last))

        XCTAssertEqual(model.rows.map(\.id), [1, 2, 3, 4])
        XCTAssertFalse(model.canLoadMore)
        let skips = SeerrStubServer.requests("GET", "/api/v1/request").map { query($0)["skip"] }
        XCTAssertEqual(skips, ["0", "3"])
    }

    func testRowsDescribeTheRequest() throws {
        let json = """
        {"id":8,"status":2,"type":"tv","createdAt":"2026-11-02T10:00:00.000Z","seasons":[{"seasonNumber":1},{"seasonNumber":2},{"seasonNumber":3}],
         "media":{"tmdbId":5,"mediaType":"tv","status":3,"downloadStatus":[{"size":100,"sizeLeft":25}]},"requestedBy":{"id":3,"displayName":"chad"}}
        """
        let request = try JSONDecoder().decode(SeerrRequest.self, from: Data(json.utf8))
        let row = try XCTUnwrap(SeerrRequestRow(request, titles: SeerrTitleCache()))
        XCTAssertEqual(row.kindLabel, "Series \u{00B7} S1\u{2013}3")
        XCTAssertEqual(row.requesterName, "chad")
        XCTAssertEqual(row.requestStatus, SeerrStatusLabel(label: "Approved", tone: .coming))
        XCTAssertEqual(row.mediaStatus, SeerrStatusLabel(label: "Processing", tone: .coming))
        XCTAssertEqual(row.progress ?? 0, 0.75, accuracy: 0.001)
    }

    // MARK: Discover

    func testDiscoverListsSeerrsRowsInOrderAndDropsAnEmptyWatchlist() async throws {
        let session = await session(id: 45, permissions: 32)
        func results(_ id: Int, _ kind: String, status: Int? = nil) -> String {
            let info = status.map { ",\"mediaInfo\":{\"status\":\($0)}" } ?? ""
            let name = kind == "movie" ? "\"title\":\"M\(id)\"" : "\"name\":\"S\(id)\""
            return "{\"page\":1,\"totalPages\":3,\"results\":[{\"id\":\(id),\"mediaType\":\"\(kind)\",\(name)\(info)}]}"
        }
        SeerrStubServer.on("GET", "/api/v1/request", body: page([request(id: 1, status: 1, by: 45, tmdbId: 9)]))
        SeerrStubServer.on("GET", "/api/v1/movie/9", body: "{\"id\":9,\"title\":\"Requested\",\"posterPath\":\"/r.jpg\"}")
        SeerrStubServer.on("GET", "/api/v1/discover/trending", body: results(10, "movie", status: 5))
        SeerrStubServer.on("GET", "/api/v1/discover/movies", body: results(11, "movie"))
        SeerrStubServer.on("GET", "/api/v1/discover/movies/upcoming", body: results(12, "movie"))
        SeerrStubServer.on("GET", "/api/v1/discover/tv", body: results(13, "tv", status: 3))
        SeerrStubServer.on("GET", "/api/v1/discover/tv/upcoming", body: results(14, "tv"))
        SeerrStubServer.on("GET", "/api/v1/discover/watchlist", body: "{\"page\":1,\"totalPages\":1,\"totalResults\":0,\"results\":[]}")
        let model = SeerrDiscoverModel(session: session)

        await model.load()

        XCTAssertEqual(model.rows.map(\.slider), [.recentRequests, .trending, .popularMovies, .upcomingMovies, .popularSeries, .upcomingSeries])
        XCTAssertEqual(model.rows.first?.items.first?.result.title, "Requested")
        XCTAssertEqual(model.rows.first?.items.first?.result.posterPath, "/r.jpg")
        XCTAssertEqual(model.rows.first?.items.first?.badge, .pending)
        XCTAssertEqual(model.rows[1].items.first?.badge, .available)
        XCTAssertEqual(model.rows[4].items.first?.badge, .coming)
        XCTAssertEqual(model.rows.first?.items.first?.discoverTag?.label, "Requested")
        XCTAssertEqual(model.rows[1].items.first?.discoverTag?.label, "Available")
        XCTAssertEqual(model.rows[4].items.first?.discoverTag?.label, "Processing")
        XCTAssertNil(model.rows[2].items.first?.discoverTag, "nobody has asked for it: no pill")
        let recent = try XCTUnwrap(SeerrStubServer.requests("GET", "/api/v1/request").first)
        XCTAssertNil(query(recent)["requestedBy"], "the server scopes Recent Requests itself")
        XCTAssertEqual(query(recent)["take"], "10")
    }

    func testAPlexWatchlistGetsItsPostersFromTheDetails() async throws {
        let session = await session(id: 45, permissions: 32)
        SeerrStubServer.on("GET", "/api/v1/discover/watchlist", body: """
        {"page":1,"totalPages":1,"totalResults":1,"results":[{"id":603,"tmdbId":603,"ratingKey":"abc","title":"The Matrix","mediaType":"movie"}]}
        """)
        SeerrStubServer.on("GET", "/api/v1/movie/603", body: "{\"id\":603,\"title\":\"The Matrix\",\"posterPath\":\"/m.jpg\",\"mediaInfo\":{\"status\":5}}")
        let model = SeerrDiscoverModel(session: session)

        await model.load()

        let row = try XCTUnwrap(model.rows.first { $0.slider == .watchlist })
        XCTAssertEqual(row.items.first?.result.tmdbId, 603)
        XCTAssertEqual(row.items.first?.result.posterPath, "/m.jpg")
        XCTAssertEqual(row.items.first?.badge, .available)
    }

    func testALocalWatchlistReadsTheTmdbIdNotTheEntryId() throws {
        let json = "{\"page\":1,\"totalPages\":1,\"results\":[{\"id\":4,\"tmdbId\":603,\"title\":\"The Matrix\",\"mediaType\":\"movie\"}]}"
        let page = try JSONDecoder().decode(SeerrSearchPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.results.first?.tmdbId, 603)
    }

    func testARowPagesOnNearItsEnd() async throws {
        let session = await session(id: 45, permissions: 32)
        SeerrStubServer.on("GET", "/api/v1/discover/trending", body: "{\"page\":1,\"totalPages\":2,\"results\":[{\"id\":1,\"mediaType\":\"movie\",\"title\":\"A\"}]}")
        SeerrStubServer.on("GET", "/api/v1/discover/trending", body: "{\"page\":2,\"totalPages\":2,\"results\":[{\"id\":2,\"mediaType\":\"movie\",\"title\":\"B\"}]}")
        let model = SeerrDiscoverModel(session: session)
        await model.load()
        let row = try XCTUnwrap(model.rows.first { $0.slider == .trending })

        await model.loadMoreIfNeeded(.trending, after: try XCTUnwrap(row.items.last))

        XCTAssertEqual(model.rows.first { $0.slider == .trending }?.items.map(\.result.title), ["A", "B"])
        let pages = SeerrStubServer.requests("GET", "/api/v1/discover/trending").map { query($0)["page"] }
        XCTAssertEqual(pages, ["1", "2"])
    }

    func testThePagesSearchKeepsTitlesThatAreOnTheServer() async {
        let session = await session(id: 45, permissions: 32)
        SeerrStubServer.on("GET", "/api/v1/search", body: """
        {"page":1,"totalPages":1,"results":[{"id":1,"mediaType":"movie","title":"On server","mediaInfo":{"status":5}},{"id":2,"mediaType":"movie","title":"Not yet"}]}
        """)
        let model = SeerrSearchModel(session: session, includesAvailable: true)
        await model.search(query: "x", library: [])
        XCTAssertEqual(model.items.map(\.badge), [.available, .request])
    }

    // MARK: Quota

    func testQuotaLines() throws {
        let unlimited = try JSONDecoder().decode(SeerrQuota.self, from: Data("""
        {"movie":{"days":7,"limit":0,"used":0,"restricted":false},"tv":{"days":7,"limit":0,"used":0,"restricted":false}}
        """.utf8))
        XCTAssertNil(unlimited.summary(for: .movie))
        XCTAssertNil(unlimited.summary(for: .tv))

        let limited = SeerrQuota(movie: SeerrQuotaStatus(days: 7, limit: 5, used: 2, remaining: 3, restricted: false),
                                 tv: SeerrQuotaStatus(days: 1, limit: 4, used: 4, remaining: 0, restricted: true))
        XCTAssertEqual(limited.summary(for: .movie), "3 of 5 movie requests left \u{00B7} resets over 7 days")
        XCTAssertEqual(limited.summary(for: .tv), "You've used all 4 of your season requests \u{00B7} resets over 1 day")
    }

    func testTheRequestPageShowsTheQuotaUnderTheButton() async {
        let session = await session(id: 45, permissions: 32)
        SeerrStubServer.on("GET", "/api/v1/movie/1", body: "{\"id\":1,\"title\":\"Jodorowsky's Dune\"}")
        SeerrStubServer.on("GET", "/api/v1/user/45/quota", body: "{\"movie\":{\"days\":7,\"limit\":5,\"used\":1,\"remaining\":4,\"restricted\":false}}")
        let model = SeerrDetailModel(target: SeerrTarget(kind: .movie, tmdbId: 1, title: "Jodorowsky's Dune"), session: session) { _, _, _ in nil }

        await model.load()

        XCTAssertEqual(model.action, .request)
        XCTAssertEqual(model.quotaNote, "4 of 5 movie requests left \u{00B7} resets over 7 days")
    }
}
