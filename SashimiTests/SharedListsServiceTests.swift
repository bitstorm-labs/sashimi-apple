import XCTest
@testable import Sashimi

/// Shared lists against a stubbed server: the production client, service and
/// store, with only the network replaced.
@MainActor
final class SharedListsServiceTests: XCTestCase {
    private let user = "me"

    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
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
        let body = try XCTUnwrap(JellyfinRouteStub.requests("POST", "/DisplayPreferences/sashimi-lists").last?.body)
        return SharedLists.subscriptions(inDisplayPreferences: body)
    }

    // MARK: Review focus 3: parental limits

    /// `ItemIds` lists every entry, including titles this viewer's parental
    /// limits hide. The count and "new" must come from the filtered listing.
    func testCountsComeFromTheViewersListingNotItemIds() async throws {
        JellyfinRouteStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"L","seen":[]}]"#))
        JellyfinRouteStub.routes["GET /Users/\(user)/Items"] = (200, items([playlist("L")]))
        JellyfinRouteStub.routes["GET /Playlists/L"] = (200, #"{"OpenAccess":true,"Shares":[{"UserId":"marge","CanEdit":true}],"ItemIds":["pg","r-rated"]}"#)
        JellyfinRouteStub.routes["GET /Playlists/L/Items"] = (200, items([movie("pg")]))

        let store = SharedListsStore(service: try service())
        await store.refresh()

        let row = try XCTUnwrap(store.rows["L"])
        XCTAssertEqual(row.contents.displayIds, ["pg"])
        XCTAssertEqual(row.newCount, 1)
        XCTAssertEqual(row.list.ownerId, "marge")
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/Playlists/L/Items").first?.query["userId"], user,
                       "the listing is asked for as this viewer, so the server applies their limits")
    }

    // MARK: Review focus 1: a list that disappears

    func testAListMadePrivateLosesItsRowAndIsPruned() async throws {
        JellyfinRouteStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"gone","seen":[]},{"id":"kept","seen":["m1"]}]"#))
        // The private list is simply absent from what this user may read.
        JellyfinRouteStub.routes["GET /Users/\(user)/Items"] = (200, items([playlist("kept")]))
        JellyfinRouteStub.routes["GET /Playlists/kept"] = (200, #"{"OpenAccess":true,"Shares":[]}"#)
        JellyfinRouteStub.routes["GET /Playlists/kept/Items"] = (200, items([movie("m1")]))
        JellyfinRouteStub.routes["POST /DisplayPreferences/sashimi-lists"] = (204, "")

        let store = SharedListsStore(service: try service())
        await store.refresh()

        XCTAssertNil(store.rows["gone"])
        XCTAssertNotNil(store.rows["kept"])
        XCTAssertEqual(try postedSubscriptions(), [ListSubscription(id: "kept", seen: ["m1"])])
        XCTAssertEqual(store.subscriptions.map(\.id), ["kept"])
    }

    func testAListWhoseSharingAnswers404IsPrunedToo() async throws {
        JellyfinRouteStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"gone","seen":[]}]"#))
        JellyfinRouteStub.routes["GET /Users/\(user)/Items"] = (200, items([playlist("gone")]))
        JellyfinRouteStub.routes["POST /DisplayPreferences/sashimi-lists"] = (204, "")

        let store = SharedListsStore(service: try service())
        await store.refresh()

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(try postedSubscriptions(), [])
    }

    func testANetworkFailureNeverPrunes() async throws {
        JellyfinRouteStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"L","seen":[]}]"#))
        JellyfinRouteStub.routes["GET /Users/\(user)/Items"] = (400, "")

        let store = SharedListsStore(service: try service())
        await store.refresh()

        XCTAssertTrue(JellyfinRouteStub.requests("POST", "/DisplayPreferences/sashimi-lists").isEmpty)
    }

    // MARK: Subscriptions

    func testSubscribingSavesWithEverythingSeenAndKeepsOtherKeys() async throws {
        JellyfinRouteStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"a","seen":[]}]"#))
        JellyfinRouteStub.routes["POST /DisplayPreferences/sashimi-lists"] = (204, "")
        let store = SharedListsStore(service: try service())
        let list = SharedList(id: "b", name: "B", ownerId: "marge", isPublic: true, imageTag: nil)
        let contents = ListContents(entries: [], items: [.listFixture(id: "x", type: .movie)])

        let saved = await store.subscribe(to: list, current: contents)

        XCTAssertTrue(saved)
        XCTAssertEqual(try postedSubscriptions(), [ListSubscription(id: "a", seen: []), ListSubscription(id: "b", seen: ["x"])])
        let request = try XCTUnwrap(JellyfinRouteStub.requests("POST", "/DisplayPreferences/sashimi-lists").last)
        XCTAssertEqual(request.query["client"], "sashimi")
        XCTAssertEqual(request.query["userId"], user)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual((object["CustomPrefs"] as? [String: Any])?["other"] as? String, "keep")
        XCTAssertEqual(store.rows["b"]?.newCount, 0)
    }

    // MARK: Creating and adding

    func testCreateSharesTheListWithItsCreator() async throws {
        JellyfinRouteStub.routes["POST /Playlists"] = (200, #"{"Id":"new"}"#)
        JellyfinRouteStub.routes["POST /Playlists/new/Users/\(user)"] = (204, "")
        JellyfinRouteStub.routes["POST /Playlists/new/Items"] = (204, "")

        let id = try await service().create(name: "Date Night", isPublic: true, adding: .listFixture(id: "m1", type: .movie))

        XCTAssertEqual(id, "new")
        let create = try XCTUnwrap(JellyfinRouteStub.requests("POST", "/Playlists").first?.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create) as? [String: Any])
        XCTAssertEqual(body["MediaType"] as? String, "Video")
        XCTAssertEqual(body["IsPublic"] as? Bool, true)
        // Created EMPTY: Jellyfin 12.4 re-saves a playlist created with items
        // a moment later and drops the self-share.
        XCTAssertEqual(body["Ids"] as? [String], [])
        let order = JellyfinRouteStub.recorded.filter { $0.method == "POST" }.map(\.path)
        XCTAssertEqual(order, ["/Playlists", "/Playlists/new/Users/\(user)", "/Playlists/new/Items"],
                       "create empty, then self-share, then add the first title")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", "/Playlists/new/Items").first?.query["ids"], "m1")
        let share = try XCTUnwrap(JellyfinRouteStub.requests("POST", "/Playlists/new/Users/\(user)").first?.body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: share) as? [String: Any])?["CanEdit"] as? Bool, true)
    }

    func testCreateDeletesTheListWhenTheSelfShareFails() async throws {
        JellyfinRouteStub.routes["POST /Playlists"] = (200, #"{"Id":"new"}"#)
        JellyfinRouteStub.routes["POST /Playlists/new/Users/\(user)"] = (403, "")
        JellyfinRouteStub.routes["DELETE /Items/new"] = (204, "")

        do {
            _ = try await service().create(name: "X", isPublic: false, adding: nil)
            XCTFail("the failed share must be reported")
        } catch {}

        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", "/Items/new").count, 1)
    }

    func testAddingAShowAddsOnlyItsFirstEpisode() async throws {
        JellyfinRouteStub.routes["GET /Shows/show/Episodes"] = (200, items([
            episode("special", series: "show", season: 0, number: 1),
            episode("s1e2", series: "show", season: 1, number: 2),
            episode("s1e1", series: "show", season: 1, number: 1),
        ]))
        JellyfinRouteStub.routes["GET /Playlists/L/Items"] = (200, items([]))
        JellyfinRouteStub.routes["POST /Playlists/L/Items"] = (204, "")

        let result = try await service().add(.listFixture(id: "show", type: .series), to: "L")

        XCTAssertEqual(result, .added)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", "/Playlists/L/Items").first?.query["ids"], "s1e1",
                       "never the series id: the server would add every episode")
    }

    func testAddingWhatIsAlreadyThereAddsNothing() async throws {
        JellyfinRouteStub.routes["GET /Playlists/L/Items"] = (200, items([movie("m1")]))

        let result = try await service().add(.listFixture(id: "m1", type: .movie), to: "L")

        XCTAssertEqual(result, .alreadyOnList)
        XCTAssertTrue(JellyfinRouteStub.requests("POST", "/Playlists/L/Items").isEmpty)
    }

    // MARK: Showing a list

    func testAPilotShowsAsItsSeriesCard() async throws {
        JellyfinRouteStub.routes["GET /Playlists/L/Items"] = (200, items([
            episode("pilot", series: "show", season: 1, number: 1), movie("m1"), movie("m1"),
        ]))
        JellyfinRouteStub.routes["GET /Users/\(user)/Items"] = (200, items(["{\"Id\":\"show\",\"Name\":\"Show\",\"Type\":\"Series\"}"]))

        let contents = try await service().contents(of: "L")

        XCTAssertEqual(contents.displayIds, ["show", "m1"])
        XCTAssertEqual(contents.items.first?.type, .series)
    }

    func testRemovingATitleRemovesEveryEntryOfIt() async throws {
        let contents = ListContents(
            entries: [.listFixture(id: "m1", type: .movie), .listFixture(id: "m2", type: .movie), .listFixture(id: "m1", type: .movie)],
            items: [.listFixture(id: "m1", type: .movie), .listFixture(id: "m2", type: .movie)]
        )
        JellyfinRouteStub.routes["DELETE /Playlists/L/Items"] = (204, "")

        try await service().remove(.listFixture(id: "m1", type: .movie), from: "L", contents: contents)

        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", "/Playlists/L/Items").first?.query["entryIds"], "m1,m1")
    }

    // MARK: Screens

    private func routeTwoLists() {
        JellyfinRouteStub.routes["GET /Items"] = (200, items([playlist("mine"), playlist("theirs")]))
        JellyfinRouteStub.routes["GET /Playlists/mine"] = (200, #"{"OpenAccess":false,"Shares":[{"UserId":"me","CanEdit":true}]}"#)
        JellyfinRouteStub.routes["GET /Playlists/theirs"] = (200, #"{"OpenAccess":true,"Shares":[{"UserId":"marge","CanEdit":true}]}"#)
        JellyfinRouteStub.routes["GET /Playlists/mine/Items"] = (200, items([movie("m1")]))
        JellyfinRouteStub.routes["GET /Playlists/theirs/Items"] = (200, items([movie("m2"), movie("m3")]))
        JellyfinRouteStub.routes["GET /Users"] = (200, #"[{"Id":"marge","Name":"Marge"},{"Id":"me","Name":"Me"}]"#)
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

    // MARK: Who made it (#784)

    /// Jellyfin 12.4 wiped every self-share when a user was deleted: the
    /// plugin still knows the owner, in one batch call.
    func testThePluginNamesTheCreatorWhenTheSelfShareIsGone() async throws {
        JellyfinRouteStub.routes["GET /Items"] = (200, items([playlist("theirs")]))
        JellyfinRouteStub.routes["GET /Playlists/theirs"] = (200, #"{"OpenAccess":true,"Shares":[]}"#)
        JellyfinRouteStub.routes["GET /Playlists/theirs/Items"] = (200, items([movie("m2")]))
        JellyfinRouteStub.routes["GET /Users"] = (200, #"[{"Id":"marge","Name":"Marge"}]"#)
        JellyfinRouteStub.routes["GET /SashimiLists/Owners"] = (200, #"{"theirs":{"OwnerUserId":"marge","OwnerName":"Marge S."}}"#)
        let service = try service()
        let model = ListsPageViewModel(service: service, store: SharedListsStore(service: service))

        await model.load()

        XCTAssertEqual(model.others.first?.list.ownerId, "marge")
        XCTAssertEqual(model.others.first?.subtitle(isOwn: false), "Marge S. · 1 title", "the plugin's name")
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/SashimiLists/Owners").map { $0.query["ids"] }, ["theirs"])
        XCTAssertTrue(JellyfinRouteStub.requests("POST", "/Playlists/theirs/Users/\(user)").isEmpty, "never claims someone else's list")
    }

    /// No plugin (404 on its route) and no self-share: the owner self-check
    /// finds your own list, and the self-share is put back for older clients.
    func testWithoutThePluginTheSelfCheckFindsYourListAndRepairsTheShare() async throws {
        JellyfinRouteStub.routes["GET /Items"] = (200, items([playlist("mine"), playlist("theirs")]))
        JellyfinRouteStub.routes["GET /Playlists/mine"] = (200, #"{"OpenAccess":true,"Shares":[]}"#)
        JellyfinRouteStub.routes["GET /Playlists/theirs"] = (200, #"{"OpenAccess":true,"Shares":[]}"#)
        JellyfinRouteStub.routes["GET /Playlists/mine/Users/\(user)"] = (200, #"{"UserId":"me","CanEdit":true}"#)
        JellyfinRouteStub.routes["GET /Playlists/theirs/Users/\(user)"] = (403, "")
        JellyfinRouteStub.routes["POST /Playlists/mine/Users/\(user)"] = (204, "")
        JellyfinRouteStub.routes["GET /Playlists/mine/Items"] = (200, items([movie("m1")]))
        JellyfinRouteStub.routes["GET /Playlists/theirs/Items"] = (200, items([movie("m2")]))
        JellyfinRouteStub.routes["GET /Users"] = (200, "[]")
        let service = try service()
        let model = ListsPageViewModel(service: service, store: SharedListsStore(service: service))

        await model.load()

        XCTAssertEqual(model.mine.map(\.id), ["mine"])
        XCTAssertEqual(model.others.map(\.id), ["theirs"])
        let repair = try XCTUnwrap(JellyfinRouteStub.requests("POST", "/Playlists/mine/Users/\(user)").first?.body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: repair) as? [String: Any])?["CanEdit"] as? Bool, true)
        XCTAssertTrue(JellyfinRouteStub.requests("POST", "/Playlists/theirs/Users/\(user)").isEmpty)
    }

    func testThePluginsOwnerIsYouRepairsAMissingSelfShare() async throws {
        JellyfinRouteStub.routes["GET /Items"] = (200, items([playlist("mine")]))
        JellyfinRouteStub.routes["GET /Playlists/mine"] = (200, #"{"OpenAccess":false,"Shares":[]}"#)
        JellyfinRouteStub.routes["GET /SashimiLists/Owners"] = (200, #"{"mine":{"OwnerUserId":"me","OwnerName":"Me"}}"#)
        JellyfinRouteStub.routes["POST /Playlists/mine/Users/\(user)"] = (204, "")

        let lists = try await service().lists()

        XCTAssertEqual(lists.first?.isOwned(by: user), true)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", "/Playlists/mine/Users/\(user)").count, 1)
        XCTAssertTrue(JellyfinRouteStub.requests("GET", "/Playlists/mine/Users/\(user)").isEmpty, "the plugin answered; no self-check")
    }

    /// Home's subscribed rows use the batch call too; your own reads "Your list".
    func testHomeRowsTakeTheOwnerFromThePlugin() async throws {
        JellyfinRouteStub.routes["GET /DisplayPreferences/sashimi-lists"] = (200, preferences(#"[{"id":"L","seen":[]},{"id":"M","seen":[]}]"#))
        JellyfinRouteStub.routes["GET /Users/\(user)/Items"] = (200, items([playlist("L"), playlist("M")]))
        JellyfinRouteStub.routes["GET /Playlists/L"] = (200, #"{"OpenAccess":true,"Shares":[]}"#)
        JellyfinRouteStub.routes["GET /Playlists/M"] = (200, #"{"OpenAccess":true,"Shares":[{"UserId":"me","CanEdit":true}]}"#)
        JellyfinRouteStub.routes["GET /Playlists/L/Items"] = (200, items([movie("m1")]))
        JellyfinRouteStub.routes["GET /Playlists/M/Items"] = (200, items([movie("m2")]))
        JellyfinRouteStub.routes["GET /SashimiLists/Owners"] = (200, #"{"L":{"OwnerUserId":"marge","OwnerName":"Marge"},"M":{"OwnerUserId":"me","OwnerName":"Me"}}"#)

        let store = SharedListsStore(service: try service())
        await store.refresh()

        XCTAssertEqual(store.rows["L"]?.title, "From Marge: List L")
        XCTAssertEqual(store.rows["M"]?.title, "Your list: List M")
        XCTAssertEqual(store.subscribedLists.map { store.rowTitle(of: $0) }, ["From Marge: List L", "Your list: List M"])
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/SashimiLists/Owners").count, 1)
    }

    /// A list's page asks the plugin for that one list.
    func testTheListPageUsesTheSingleOwnerCall() async throws {
        JellyfinRouteStub.routes["GET /SashimiLists/Playlists/L/Owner"] = (200, #"{"OwnerUserId":"me","OwnerName":"Me"}"#)
        JellyfinRouteStub.routes["GET /Playlists/L"] = (200, #"{"OpenAccess":true,"Shares":[]}"#)
        JellyfinRouteStub.routes["POST /Playlists/L/Users/\(user)"] = (204, "")
        JellyfinRouteStub.routes["GET /Playlists/L/Items"] = (200, items([movie("m1")]))
        JellyfinRouteStub.routes["GET /Users"] = (200, "[]")
        let service = try service()
        let stale = SharedList(id: "L", name: "L", ownerId: nil, isPublic: false, imageTag: nil)
        let model = ListDetailViewModel(list: stale, service: service, store: SharedListsStore(service: service))

        await model.load()

        XCTAssertTrue(model.isOwner)
        XCTAssertEqual(model.creatorLine, "Your list")
        XCTAssertTrue(model.list.isPublic, "the server's OpenAccess, not the card's")
        XCTAssertTrue(JellyfinRouteStub.requests("GET", "/SashimiLists/Owners").isEmpty)
    }

    // MARK: Public/Private is the server's (#785)

    private func detailModel(isPublic: Bool) throws -> ListDetailViewModel {
        let service = try service()
        let list = SharedList(id: "L", name: "L", ownerId: user, isPublic: isPublic, imageTag: nil)
        return ListDetailViewModel(list: list, service: service, store: SharedListsStore(service: service), settle: .zero)
    }

    /// A queued server refresh reverts the switch a second later: it is
    /// applied once more, and what shows is what the server then says.
    func testARevertedSwitchIsAppliedAgain() async throws {
        JellyfinRouteStub.routes["POST /Playlists/L"] = (204, "")
        JellyfinRouteStub.sequences["GET /Playlists/L"] = [(200, #"{"OpenAccess":false}"#), (200, #"{"OpenAccess":true}"#)]
        let model = try detailModel(isPublic: false)

        let ok = await model.togglePublic()

        XCTAssertTrue(ok)
        XCTAssertTrue(model.list.isPublic)
        let posts = JellyfinRouteStub.requests("POST", "/Playlists/L").compactMap(\.body)
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(posts.compactMap { $0["IsPublic"] as? Bool }, [true, true])
    }

    /// The switch never shows a value the server does not have.
    func testTheSwitchShowsTheServersValueWhenItWillNotStick() async throws {
        JellyfinRouteStub.routes["POST /Playlists/L"] = (204, "")
        JellyfinRouteStub.routes["GET /Playlists/L"] = (200, #"{"OpenAccess":false}"#)
        let model = try detailModel(isPublic: false)

        let ok = await model.togglePublic()

        XCTAssertFalse(ok)
        XCTAssertFalse(model.list.isPublic)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", "/Playlists/L").count, 2, "re-applied once, not forever")
    }

    func testASwitchThatSticksIsAppliedOnce() async throws {
        JellyfinRouteStub.routes["POST /Playlists/L"] = (204, "")
        JellyfinRouteStub.routes["GET /Playlists/L"] = (200, #"{"OpenAccess":false}"#)
        let model = try detailModel(isPublic: true)

        let ok = await model.togglePublic()

        XCTAssertTrue(ok)
        XCTAssertFalse(model.list.isPublic)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", "/Playlists/L").count, 1)
    }
}
