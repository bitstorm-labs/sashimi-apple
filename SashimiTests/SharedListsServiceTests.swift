import XCTest
@testable import Sashimi

/// Answers "METHOD /path" from a table and records every request with its body.
private final class ListsStub: URLProtocol {
    struct Recorded {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
    }

    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var recorded: [Recorded] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, text) = Self.lock.withLock {
            Self.recorded.append(Recorded(method: method, path: url.path, query: query, body: body))
            return Self.routes["\(method) \(url.path)"] ?? (404, "")
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func requests(_ method: String, _ path: String) -> [Recorded] {
        lock.withLock { recorded.filter { $0.method == method && $0.path == path } }
    }
}

/// Shared lists against a stubbed server: the production client, service and
/// store, with only the network replaced.
@MainActor
final class SharedListsServiceTests: XCTestCase {
    private let user = "me"

    override func setUp() {
        super.setUp()
        ListsStub.routes = [:]
        ListsStub.recorded = []
        JellyfinClient.testURLProtocolClasses = [ListsStub.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func service() throws -> SharedListsService {
        SharedListsService(client: JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://stub.local")),
            accessToken: "token",
            userId: user
        ))
    }

    private func items(_ json: [String]) -> String {
        "{\"Items\":[\(json.joined(separator: ","))],\"TotalRecordCount\":\(json.count)}"
    }

    private func movie(_ id: String) -> String {
        "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Movie\",\"PlaylistItemId\":\"entry-\(id)\"}"
    }

    private func episode(_ id: String, series: String, season: Int, number: Int) -> String {
        "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Episode\",\"SeriesId\":\"\(series)\",\"ParentIndexNumber\":\(season),\"IndexNumber\":\(number)}"
    }

    private func playlist(_ id: String) -> String {
        "{\"Id\":\"\(id)\",\"Name\":\"List \(id)\",\"Type\":\"Playlist\"}"
    }

    private func preferences(_ subscriptions: String, extra: String = "\"other\":\"keep\"") -> String {
        let escaped = subscriptions.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"Id\":\"p\",\"Client\":\"sashimi\",\"CustomPrefs\":{\(extra),\"subscriptions\":\"\(escaped)\"}}"
    }

    private func postedSubscriptions() throws -> [ListSubscription] {
        let body = try XCTUnwrap(ListsStub.requests("POST", "/DisplayPreferences/sashimi-lists").last?.body)
        return SharedLists.subscriptions(inDisplayPreferences: body)
    }

    // MARK: Review focus 3: parental limits

    /// `ItemIds` lists every entry, including titles this viewer's parental
    /// limits hide. The count and "new" must come from the filtered listing.
    func testCountsComeFromTheViewersListingNotItemIds() async throws {
        ListsStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"L","seen":[]}]"#))
        ListsStub.routes["GET /Users/\(user)/Items"] = (200, items([playlist("L")]))
        ListsStub.routes["GET /Playlists/L"] = (200, #"{"OpenAccess":true,"Shares":[{"UserId":"marge","CanEdit":true}],"ItemIds":["pg","r-rated"]}"#)
        ListsStub.routes["GET /Playlists/L/Items"] = (200, items([movie("pg")]))

        let store = SharedListsStore(service: try service())
        await store.refresh()

        let row = try XCTUnwrap(store.rows["L"])
        XCTAssertEqual(row.contents.displayIds, ["pg"])
        XCTAssertEqual(row.newCount, 1)
        XCTAssertEqual(row.list.ownerId, "marge")
        XCTAssertEqual(ListsStub.requests("GET", "/Playlists/L/Items").first?.query["userId"], user,
                       "the listing is asked for as this viewer, so the server applies their limits")
    }

    // MARK: Review focus 1: a list that disappears

    func testAListMadePrivateLosesItsRowAndIsPruned() async throws {
        ListsStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"gone","seen":[]},{"id":"kept","seen":["m1"]}]"#))
        // The private list is simply absent from what this user may read.
        ListsStub.routes["GET /Users/\(user)/Items"] = (200, items([playlist("kept")]))
        ListsStub.routes["GET /Playlists/kept"] = (200, #"{"OpenAccess":true,"Shares":[]}"#)
        ListsStub.routes["GET /Playlists/kept/Items"] = (200, items([movie("m1")]))
        ListsStub.routes["POST /DisplayPreferences/sashimi-lists"] = (204, "")

        let store = SharedListsStore(service: try service())
        await store.refresh()

        XCTAssertNil(store.rows["gone"])
        XCTAssertNotNil(store.rows["kept"])
        XCTAssertEqual(try postedSubscriptions(), [ListSubscription(id: "kept", seen: ["m1"])])
        XCTAssertEqual(store.subscriptions.map(\.id), ["kept"])
    }

    func testAListWhoseSharingAnswers404IsPrunedToo() async throws {
        ListsStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"gone","seen":[]}]"#))
        ListsStub.routes["GET /Users/\(user)/Items"] = (200, items([playlist("gone")]))
        ListsStub.routes["POST /DisplayPreferences/sashimi-lists"] = (204, "")

        let store = SharedListsStore(service: try service())
        await store.refresh()

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(try postedSubscriptions(), [])
    }

    func testANetworkFailureNeverPrunes() async throws {
        ListsStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"L","seen":[]}]"#))
        ListsStub.routes["GET /Users/\(user)/Items"] = (400, "")

        let store = SharedListsStore(service: try service())
        await store.refresh()

        XCTAssertTrue(ListsStub.requests("POST", "/DisplayPreferences/sashimi-lists").isEmpty)
    }

    // MARK: Subscriptions

    func testSubscribingSavesWithEverythingSeenAndKeepsOtherKeys() async throws {
        ListsStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"a","seen":[]}]"#))
        ListsStub.routes["POST /DisplayPreferences/sashimi-lists"] = (204, "")
        let store = SharedListsStore(service: try service())
        let list = SharedList(id: "b", name: "B", ownerId: "marge", isPublic: true, imageTag: nil)
        let contents = ListContents(entries: [], items: [.listFixture(id: "x", type: .movie)])

        let saved = await store.subscribe(to: list, current: contents)

        XCTAssertTrue(saved)
        XCTAssertEqual(try postedSubscriptions(), [ListSubscription(id: "a", seen: []), ListSubscription(id: "b", seen: ["x"])])
        let request = try XCTUnwrap(ListsStub.requests("POST", "/DisplayPreferences/sashimi-lists").last)
        XCTAssertEqual(request.query["client"], "sashimi")
        XCTAssertEqual(request.query["userId"], user)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual((object["CustomPrefs"] as? [String: Any])?["other"] as? String, "keep")
        XCTAssertEqual(store.rows["b"]?.newCount, 0)
    }

    // MARK: Creating and adding

    func testCreateSharesTheListWithItsCreator() async throws {
        ListsStub.routes["POST /Playlists"] = (200, #"{"Id":"new"}"#)
        ListsStub.routes["POST /Playlists/new/Users/\(user)"] = (204, "")
        ListsStub.routes["POST /Playlists/new/Items"] = (204, "")

        let id = try await service().create(name: "Date Night", isPublic: true, adding: .listFixture(id: "m1", type: .movie))

        XCTAssertEqual(id, "new")
        let create = try XCTUnwrap(ListsStub.requests("POST", "/Playlists").first?.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create) as? [String: Any])
        XCTAssertEqual(body["MediaType"] as? String, "Video")
        XCTAssertEqual(body["IsPublic"] as? Bool, true)
        // Created EMPTY: Jellyfin 12.4 re-saves a playlist created with items
        // a moment later and drops the self-share.
        XCTAssertEqual(body["Ids"] as? [String], [])
        let order = ListsStub.recorded.filter { $0.method == "POST" }.map(\.path)
        XCTAssertEqual(order, ["/Playlists", "/Playlists/new/Users/\(user)", "/Playlists/new/Items"],
                       "create empty, then self-share, then add the first title")
        XCTAssertEqual(ListsStub.requests("POST", "/Playlists/new/Items").first?.query["ids"], "m1")
        let share = try XCTUnwrap(ListsStub.requests("POST", "/Playlists/new/Users/\(user)").first?.body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: share) as? [String: Any])?["CanEdit"] as? Bool, true)
    }

    func testCreateDeletesTheListWhenTheSelfShareFails() async throws {
        ListsStub.routes["POST /Playlists"] = (200, #"{"Id":"new"}"#)
        ListsStub.routes["POST /Playlists/new/Users/\(user)"] = (403, "")
        ListsStub.routes["DELETE /Items/new"] = (204, "")

        do {
            _ = try await service().create(name: "X", isPublic: false, adding: nil)
            XCTFail("the failed share must be reported")
        } catch {}

        XCTAssertEqual(ListsStub.requests("DELETE", "/Items/new").count, 1)
    }

    func testAddingAShowAddsOnlyItsFirstEpisode() async throws {
        ListsStub.routes["GET /Shows/show/Episodes"] = (200, items([
            episode("special", series: "show", season: 0, number: 1),
            episode("s1e2", series: "show", season: 1, number: 2),
            episode("s1e1", series: "show", season: 1, number: 1),
        ]))
        ListsStub.routes["GET /Playlists/L/Items"] = (200, items([]))
        ListsStub.routes["POST /Playlists/L/Items"] = (204, "")

        let result = try await service().add(.listFixture(id: "show", type: .series), to: "L")

        XCTAssertEqual(result, .added)
        XCTAssertEqual(ListsStub.requests("POST", "/Playlists/L/Items").first?.query["ids"], "s1e1",
                       "never the series id: the server would add every episode")
    }

    func testAddingWhatIsAlreadyThereAddsNothing() async throws {
        ListsStub.routes["GET /Playlists/L/Items"] = (200, items([movie("m1")]))

        let result = try await service().add(.listFixture(id: "m1", type: .movie), to: "L")

        XCTAssertEqual(result, .alreadyOnList)
        XCTAssertTrue(ListsStub.requests("POST", "/Playlists/L/Items").isEmpty)
    }

    // MARK: Showing a list

    func testAPilotShowsAsItsSeriesCard() async throws {
        ListsStub.routes["GET /Playlists/L/Items"] = (200, items([
            episode("pilot", series: "show", season: 1, number: 1), movie("m1"), movie("m1"),
        ]))
        ListsStub.routes["GET /Users/\(user)/Items"] = (200, items(["{\"Id\":\"show\",\"Name\":\"Show\",\"Type\":\"Series\"}"]))

        let contents = try await service().contents(of: "L")

        XCTAssertEqual(contents.displayIds, ["show", "m1"])
        XCTAssertEqual(contents.items.first?.type, .series)
    }

    func testRemovingATitleRemovesEveryEntryOfIt() async throws {
        let contents = ListContents(
            entries: [.listFixture(id: "m1", type: .movie), .listFixture(id: "m2", type: .movie), .listFixture(id: "m1", type: .movie)],
            items: [.listFixture(id: "m1", type: .movie), .listFixture(id: "m2", type: .movie)]
        )
        ListsStub.routes["DELETE /Playlists/L/Items"] = (204, "")

        try await service().remove(.listFixture(id: "m1", type: .movie), from: "L", contents: contents)

        XCTAssertEqual(ListsStub.requests("DELETE", "/Playlists/L/Items").first?.query["entryIds"], "m1,m1")
    }

    // MARK: Screens

    private func routeTwoLists() {
        ListsStub.routes["GET /Items"] = (200, items([playlist("mine"), playlist("theirs")]))
        ListsStub.routes["GET /Playlists/mine"] = (200, #"{"OpenAccess":false,"Shares":[{"UserId":"me","CanEdit":true}]}"#)
        ListsStub.routes["GET /Playlists/theirs"] = (200, #"{"OpenAccess":true,"Shares":[{"UserId":"marge","CanEdit":true}]}"#)
        ListsStub.routes["GET /Playlists/mine/Items"] = (200, items([movie("m1")]))
        ListsStub.routes["GET /Playlists/theirs/Items"] = (200, items([movie("m2"), movie("m3")]))
        ListsStub.routes["GET /Users"] = (200, #"[{"Id":"marge","Name":"Marge"},{"Id":"me","Name":"Me"}]"#)
    }

    func testTheListsPageSplitsYourListsFromOthersAndNamesTheCreator() async throws {
        routeTwoLists()
        let service = try service()
        let model = ListsPageViewModel(service: service, store: SharedListsStore(service: service))

        await model.load()

        XCTAssertEqual(model.mine.map(\.id), ["mine"])
        XCTAssertEqual(model.others.map(\.id), ["theirs"])
        XCTAssertEqual(model.mine.first?.subtitle(isOwn: true), "Private · 1 title")
        XCTAssertEqual(model.others.first?.subtitle(isOwn: false), "Marge · 2 titles")
    }

    /// The picker offers only your own lists, and says where the title is.
    func testThePickerOffersYourListsAndMarksWhereTheTitleIs() async throws {
        routeTwoLists()
        let model = AddToListViewModel(item: .listFixture(id: "m1", type: .movie), service: try service())

        await model.load()

        XCTAssertEqual(model.choices.map(\.id), ["mine"])
        XCTAssertEqual(model.choices.first?.alreadyOn, true)
        XCTAssertEqual(model.choices.first?.detail, "Already on this list")
    }
}
