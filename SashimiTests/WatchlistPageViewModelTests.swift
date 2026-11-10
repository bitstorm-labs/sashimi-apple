import XCTest
@testable import Sashimi

/// The Watchlist page model against a stubbed Jellyfin and Seerr.
@MainActor
final class WatchlistPageViewModelTests: XCTestCase {
    private let base = "/SashimiLists/Watchlist"
    private var credentials = InMemorySeerrCredentials()

    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        SeerrStubServer.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        SeerrClient.testURLProtocolClasses = [SeerrStubServer.self]
        credentials = InMemorySeerrCredentials()
        WatchlistPageViewModel.resetSharedLookups()
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        SeerrClient.testURLProtocolClasses = []
        super.tearDown()
    }

    // MARK: Fixtures

    private func jellyfin() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
    }

    private func entryJSON(_ id: String, type: String = "Movie", tmdb: Int? = nil, itemId: String? = nil) -> String {
        let tmdbPart = tmdb.map { ",\"tmdbId\":\"\($0)\"" } ?? ""
        let itemPart = itemId.map { ",\"itemId\":\"\($0)\"" } ?? ""
        return "{\"id\":\"\(id)\",\"type\":\"\(type)\",\"title\":\"Title \(id)\"\(tmdbPart)\(itemPart)}"
    }

    private func listJSON(entries: [String], plex: String? = nil, needsReconnect: Bool = false, dismissed: Bool = false) -> String {
        let plexPart = plex.map { "\"plex\":{\"username\":\"\($0)\",\"needsReconnect\":\(needsReconnect)}," } ?? ""
        return "{\(plexPart)\"cardDismissed\":\(dismissed),\"entries\":[\(entries.joined(separator: ","))]}"
    }

    private func serve(_ entries: [String], plex: String? = nil, needsReconnect: Bool = false, dismissed: Bool = false) {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(entries: entries, plex: plex, needsReconnect: needsReconnect, dismissed: dismissed))
    }

    private func serveItems(_ ids: [String]) {
        let items = ids.map { "{\"Id\":\"\($0)\",\"Name\":\"Item \($0)\",\"Type\":\"Movie\"}" }
        JellyfinRouteStub.routes["GET /Users/me/Items"] = (200, "{\"Items\":[\(items.joined(separator: ","))],\"TotalRecordCount\":\(ids.count)}")
    }

    private func signedInSeerr() async -> SeerrSession {
        let session = SeerrSession(defaults: SeerrFixtures.defaults(), credentials: credentials, pollInterval: .zero)
        _ = session.setServerAddress(SeerrFixtures.server.absoluteString)
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(id: 7), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await session.signInLocal(email: "test@example.com", password: "pw")
        SeerrStubServer.reset()
        return session
    }

    private func signedOutSeerr() -> SeerrSession {
        SeerrSession(defaults: SeerrFixtures.defaults(), credentials: credentials, pollInterval: .zero)
    }

    private func makeModel(seerr: SeerrSession, lookup: RequestedLookup? = nil) throws -> WatchlistPageViewModel {
        try makeModelAndStore(seerr: seerr, lookup: lookup).model
    }

    private func tile(_ model: WatchlistPageViewModel, _ index: Int) throws -> WatchlistTile {
        try XCTUnwrap(model.tiles.indices.contains(index) ? model.tiles[index] : nil, "tile \(index)")
    }

    private func detailsJSON(_ id: Int) -> String { "{\"id\":\(id),\"title\":\"T\(id)\",\"mediaInfo\":{\"status\":2}}" }

    // MARK: Tiles

    func testOnServerTilesCarryTheirLibraryItemAndMissingOnesAreTagged() async throws {
        serve([entryJSON("a", tmdb: 1, itemId: "i1"), entryJSON("b", tmdb: 2)])
        serveItems(["i1"])
        let model = try makeModel(seerr: signedOutSeerr())

        await model.load()

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.tiles.map(\.id), ["a", "b"])
        XCTAssertEqual((try tile(model, 0)).libraryItem?.id, "i1")
        XCTAssertNil((try tile(model, 0)).missingTag)
        XCTAssertFalse((try tile(model, 0)).isMissing)
        XCTAssertNil((try tile(model, 1)).libraryItem)
        XCTAssertEqual((try tile(model, 1)).missingTag, .notOnServer)
        XCTAssertTrue((try tile(model, 1)).isMissing)
        XCTAssertEqual(model.summary, "Private · 2 titles")
    }

    func testAnItemTheViewerCantSeeIsMissing() async throws {
        serve([entryJSON("a", tmdb: 1, itemId: "hidden")])
        serveItems([])
        let model = try makeModel(seerr: signedOutSeerr())

        await model.load()

        XCTAssertNil(model.tiles.first?.libraryItem)
        XCTAssertEqual(model.tiles.first?.missingTag, .notOnServer)
    }

    func testRequestedOnlyWithASeerrSession() async throws {
        serve([entryJSON("a", tmdb: 1)])
        let fake = CountingLookup()
        fake.status = 2

        let signedOut = try makeModel(seerr: signedOutSeerr(), lookup: { fake($0) })
        await signedOut.load()
        signedOut.tileAppeared(try XCTUnwrap(signedOut.tiles.first))
        await signedOut.waitForLookups()
        XCTAssertTrue(fake.batches.isEmpty)
        XCTAssertEqual(signedOut.tiles.first?.missingTag, .notOnServer)

        let signedIn = try makeModel(seerr: await signedInSeerr(), lookup: { fake($0) })
        await signedIn.load()
        signedIn.tileAppeared(try XCTUnwrap(signedIn.tiles.first))
        await signedIn.waitForLookups()
        XCTAssertEqual(fake.asked.map(\.tmdbId), [1])
        XCTAssertEqual(signedIn.tiles.first?.missingTag, .requested)
    }

    func testLoadingTheWatchlistMakesNoSeerrCalls() async throws {
        serve((1...40).map { entryJSON("e\($0)", tmdb: $0) })
        let fake = CountingLookup()
        let model = try makeModel(seerr: await signedInSeerr(), lookup: { fake($0) })

        await model.load()
        await model.waitForLookups()

        XCTAssertEqual(model.tiles.count, 40)
        XCTAssertTrue(fake.batches.isEmpty)
        XCTAssertTrue(SeerrStubServer.requests.isEmpty)
    }

    func testRequestedLookupsRunAtMostFourAtOnce() async throws {
        serve((1...40).map { entryJSON("e\($0)", tmdb: $0) })
        let session = await signedInSeerr()
        for id in 1...40 { SeerrStubServer.on("GET", "/api/v1/movie/\(id)", body: detailsJSON(id)) }
        SeerrStubServer.detailsDelay = 0.05
        let client = try XCTUnwrap(session.client)
        let cache = SeerrTitleCache()
        let model = try makeModel(seerr: session, lookup: { targets in
            await cache.fill(targets, client: client, maxConcurrent: 4)
            var result: [String: SeerrMediaInfo?] = [:]
            for target in targets {
                if let entry = cache.entry(for: target) { result.updateValue(entry.mediaInfo, forKey: target.id) }
            }
            return result
        })

        await model.load()
        model.tiles.forEach(model.tileAppeared)
        await model.waitForLookups()

        XCTAssertLessThanOrEqual(SeerrStubServer.peakDetailsInFlight, 4)
        XCTAssertGreaterThan(SeerrStubServer.peakDetailsInFlight, 1, "the lookups did overlap")
        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v1/movie/1").count, 1)
        XCTAssertEqual(Set(SeerrStubServer.requests.map(\.path)).count, 40)
        XCTAssertEqual(model.tiles.filter { $0.missingTag == .requested }.count, 40)
    }

    func testATitleIsLookedUpOnceAcrossReloads() async throws {
        serve([entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2)])
        let fake = CountingLookup()
        fake.status = 2
        let model = try makeModel(seerr: await signedInSeerr(), lookup: { fake($0) })

        await model.load()
        model.tiles.forEach(model.tileAppeared)
        model.tiles.forEach(model.tileAppeared) // scrolled away and back before the answer
        await model.waitForLookups()
        await model.load()
        XCTAssertEqual(model.tiles.map(\.missingTag), [.requested, .requested], "known results apply at once")
        model.tiles.forEach(model.tileAppeared)
        await model.waitForLookups()

        XCTAssertEqual(fake.asked.map(\.tmdbId).sorted(), [1, 2])
    }

    func testSeerrFailingStillFinishesLoadingWithNotOnServer() async throws {
        serve([entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2)])
        let session = await signedInSeerr()
        SeerrStubServer.on("GET", "/api/v1/movie/1", status: 500, body: "{}")
        SeerrStubServer.on("GET", "/api/v1/movie/2", status: 500, body: "{}")
        let model = try makeModel(seerr: session)

        await model.load()
        model.tiles.forEach(model.tileAppeared)
        await model.waitForLookups()
        model.tiles.forEach(model.tileAppeared)
        await model.waitForLookups()

        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.tiles.map(\.missingTag), [.notOnServer, .notOnServer])
        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v1/movie/1").count, 1, "a failure isn't retried this session")

        let nextVisit = try makeModel(seerr: session)
        await nextVisit.load()
        nextVisit.tiles.forEach(nextVisit.tileAppeared)
        await nextVisit.waitForLookups()
        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v1/movie/1").count, 1, "nor on the next visit to the page")
    }

    func testAnAnswerThatArrivesAfterTheSeerrUserChangedIsDropped() async throws {
        serve([entryJSON("a", tmdb: 1)])
        let fake = CountingLookup()
        fake.status = 2
        let session = await signedInSeerr()
        let model = try makeModel(seerr: session, lookup: { targets in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return fake(targets)
        })
        await model.load()
        model.tiles.forEach(model.tileAppeared)

        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(id: 8), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await session.signInLocal(email: "other@example.com", password: "pw")
        await model.waitForLookups()

        XCTAssertEqual(model.tiles.first?.missingTag, .notOnServer, "the last person's answer isn't shown to this one")
        model.tiles.forEach(model.tileAppeared)
        await model.waitForLookups()
        XCTAssertEqual(fake.batches.count, 2, "asked again for the new person")
        XCTAssertEqual(model.tiles.first?.missingTag, .requested)
    }

    /// A detail cover hides the page (cancelling its lookups) and the grid's
    /// visible tiles don't appear again when it closes: the reload asks again.
    func testLookupsCutShortByACoverRunAgainOnTheReload() async throws {
        serve([entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2)])
        let fake = CountingLookup()
        fake.status = 2
        let model = try makeModel(seerr: await signedInSeerr(), lookup: { targets in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return fake(targets)
        })
        await model.load()
        model.tiles.forEach(model.tileAppeared)
        try await Task.sleep(nanoseconds: 50_000_000) // under way

        model.cancelLookups() // the cover opened
        await model.load()    // and closed: no tileAppeared this time
        await model.waitForLookups()

        XCTAssertEqual(model.tiles.map(\.missingTag), [.requested, .requested])
        XCTAssertEqual(fake.batches.count, 2, "the cut-short batch, then once more")
        XCTAssertEqual(fake.batches.last?.map(\.tmdbId).sorted(), [1, 2])
    }

    func testCancelledLookupsDropTheirAnswersAndCanBeAskedAgain() async throws {
        serve([entryJSON("a", tmdb: 1)])
        let fake = CountingLookup()
        fake.status = 2
        let model = try makeModel(seerr: await signedInSeerr(), lookup: { targets in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return fake(targets)
        })
        await model.load()
        model.tiles.forEach(model.tileAppeared)
        try await Task.sleep(nanoseconds: 50_000_000) // the lookup is under way

        model.cancelLookups()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(model.tiles.first?.missingTag, .notOnServer, "a page that went away takes no answers")
        model.tiles.forEach(model.tileAppeared)
        await model.waitForLookups()
        XCTAssertEqual(model.tiles.first?.missingTag, .requested, "and can ask again when it comes back")
    }

    // MARK: Header and menu

    func testHeaderAndMenuFollowTheLink() async throws {
        struct Row {
            let plex: String?
            let reconnect: Bool
            let dismissed: Bool
            let header: WatchlistHeader
            let menu: [WatchlistMenuItem]
        }
        let cases = [
            Row(plex: nil, reconnect: false, dismissed: false, header: .connectCard, menu: [.connectPlex, .removeTitles]),
            Row(plex: nil, reconnect: false, dismissed: true, header: .none, menu: [.connectPlex, .removeTitles]),
            Row(plex: "marge", reconnect: false, dismissed: false, header: .synced, menu: [.disconnectPlex, .removeTitles]),
            Row(plex: "marge", reconnect: true, dismissed: false, header: .needsReconnect,
                menu: [.reconnectPlex, .disconnectPlex, .removeTitles])
        ]
        for row in cases {
            serve([entryJSON("a", tmdb: 1)], plex: row.plex, needsReconnect: row.reconnect, dismissed: row.dismissed)
            let model = try makeModel(seerr: signedOutSeerr())
            await model.load()
            XCTAssertEqual(model.header, row.header, "\(row)")
            XCTAssertEqual(model.menuItems, row.menu, "\(row)")
        }
        serve([])
        let empty = try makeModel(seerr: signedOutSeerr())
        await empty.load()
        XCTAssertEqual(empty.menuItems, [.connectPlex], "nothing to remove")
    }

    // MARK: Actions

    func testTappingAMissingTitleWithoutRequestsExplains() async throws {
        serve([entryJSON("a", tmdb: 1), entryJSON("b")])
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()

        XCTAssertEqual(model.action(for: try tile(model, 0)), .explain("Sign into Requests to ask for this"))
        XCTAssertEqual(model.action(for: try tile(model, 1)), .explain("Requests can't look this title up."))
    }

    func testTappingAMissingTitleWithRequestsOpensItsRequestPage() async throws {
        serve([entryJSON("a", tmdb: 1), entryJSON("s", type: "Series", tmdb: 5), entryJSON("b"), entryJSON("c", tmdb: 3, itemId: "i3")])
        serveItems(["i3"])
        let model = try makeModel(seerr: await signedInSeerr())
        await model.load()

        XCTAssertEqual(model.action(for: try tile(model, 0)), .openRequest(SeerrTarget(kind: .movie, tmdbId: 1, title: "Title a")))
        XCTAssertEqual(model.action(for: try tile(model, 1)), .openRequest(SeerrTarget(kind: .tv, tmdbId: 5, title: "Title s")))
        XCTAssertEqual(model.action(for: try tile(model, 2)), .explain("Requests can't look this title up."))
        guard case .openLibrary(let item) = model.action(for: try tile(model, 3)) else { return XCTFail("on-server tile opens the library") }
        XCTAssertEqual(item.id, "i3")
    }

    func testNotNowDismissesTheCardOnTheServer() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON(entries: [])), (200, listJSON(entries: [], dismissed: true))]
        JellyfinRouteStub.routes["POST \(base)/DismissCard"] = (204, "")
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.header, .connectCard)

        await model.dismissCard()

        XCTAssertEqual(JellyfinRouteStub.recorded.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(model.header, .none)
    }

    func testDisconnectKeepsTheEntries() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON(entries: [entryJSON("a", tmdb: 1)], plex: "marge")),
            (200, listJSON(entries: [entryJSON("a", tmdb: 1)]))
        ]
        JellyfinRouteStub.routes["DELETE \(base)/Plex"] = (204, "")
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.header, .synced)

        let done = await model.disconnect()

        XCTAssertTrue(done)
        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", "\(base)/Plex").count, 1)
        XCTAssertEqual(model.header, .connectCard)
        XCTAssertEqual(model.tiles.map(\.id), ["a"])
    }

    func testRemovingATitleDeletesItsEntry() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON(entries: [entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2)])),
            (200, listJSON(entries: [entryJSON("b", tmdb: 2)]))
        ]
        JellyfinRouteStub.routes["DELETE \(base)/Items/a"] = (204, "")
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()

        let done = await model.remove(try tile(model, 0))

        XCTAssertTrue(done)
        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", "\(base)/Items/a").count, 1)
        XCTAssertEqual(model.tiles.map(\.id), ["b"])
        XCTAssertEqual(model.summary, "Private · 1 title")
    }

    func testNoPluginMeansGone() async throws {
        let model = try makeModel(seerr: signedOutSeerr())

        await model.load()

        XCTAssertTrue(model.isGone)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.tiles.isEmpty)
    }
}

// MARK: Link changes made elsewhere

extension WatchlistPageViewModelTests {
    private func makeModelAndStore(seerr: SeerrSession, lookup: RequestedLookup? = nil) throws
        -> (model: WatchlistPageViewModel, store: WatchlistStore) {
        let service = WatchlistService(client: try jellyfin())
        let store = WatchlistStore(service: service)
        return (WatchlistPageViewModel(store: store, service: service, seerr: seerr, lookup: lookup), store)
    }

    /// Waits (bounded) for something the page does on its own after a store change.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Connect Plex (or Settings, or Requests' auto-link) links while the page
    /// is open; Plex's sync brings titles the server has: the grid follows.
    func testTilesFollowALinkMadeElsewhere() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON(entries: [entryJSON("a", tmdb: 1, itemId: "i1")])),
            (200, listJSON(entries: [entryJSON("a", tmdb: 1, itemId: "i1"), entryJSON("b", tmdb: 2, itemId: "i2"),
                                     entryJSON("c", tmdb: 3)], plex: "marge"))
        ]
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        serveItems(["i1", "i2"])
        let (model, store) = try makeModelAndStore(seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.tiles.map(\.id), ["a"])

        _ = await store.link(token: "T", replace: false)
        await eventually { model.tiles.count == 3 }

        XCTAssertEqual(model.header, .synced)
        XCTAssertEqual(model.tiles.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(model.summary, "Private · 3 titles")
        XCTAssertEqual(try tile(model, 1).libraryItem?.id, "i2", "a synced title the server has isn't 'Not on server'")
        XCTAssertEqual(try tile(model, 2).missingTag, .notOnServer)
    }

    /// The first load failed; a later load (the store's, from anywhere)
    /// brings the Watchlist: the page shows it instead of the error.
    func testAFailedFirstLoadRecoversWhenTheWatchlistArrives() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, "not json"),
            (200, listJSON(entries: [entryJSON("a", tmdb: 1)]))
        ]
        let (model, store) = try makeModelAndStore(seerr: signedOutSeerr())
        await model.load()
        XCTAssertTrue(model.failed)

        await store.refresh()
        await eventually { !model.failed }

        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.tiles.map(\.id), ["a"])
    }

    func testTilesFollowADisconnectAndAQuietRelink() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON(entries: [entryJSON("a", tmdb: 1)], plex: "marge", needsReconnect: true)),
            (200, listJSON(entries: [entryJSON("a", tmdb: 1)])),
            (200, listJSON(entries: [entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2, itemId: "i2")], plex: "marge"))
        ]
        JellyfinRouteStub.routes["DELETE \(base)/Plex"] = (204, "")
        JellyfinRouteStub.routes["POST \(base)/Plex"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        serveItems(["i2"])
        let (model, store) = try makeModelAndStore(seerr: signedOutSeerr())
        await model.load()
        XCTAssertEqual(model.header, .needsReconnect)

        let disconnected = await model.disconnect()
        XCTAssertTrue(disconnected)
        XCTAssertEqual(model.header, .connectCard)
        XCTAssertEqual(model.tiles.map(\.id), ["a"])

        await store.autoLink(token: "T") // Requests sign-in with the same account
        await eventually { model.tiles.count == 2 }

        XCTAssertEqual(model.header, .synced, "needsReconnect is gone")
        XCTAssertEqual(model.tiles.map(\.id), ["a", "b"])
        XCTAssertEqual(try tile(model, 1).libraryItem?.id, "i2")
    }
}

// MARK: Removing titles

extension WatchlistPageViewModelTests {
    /// Two quick removes, the first fails: nothing is lost, moved or doubled.
    func testAFailedRemoveLeavesEveryTitleInItsPlaceAndALaterRemoveRemovesOnlyItsOwn() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON(entries: [entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2), entryJSON("c", tmdb: 3)])),
            (200, listJSON(entries: [entryJSON("a", tmdb: 1), entryJSON("c", tmdb: 3)]))
        ]
        JellyfinRouteStub.routes["DELETE \(base)/Items/a"] = (500, "")
        JellyfinRouteStub.routes["DELETE \(base)/Items/b"] = (204, "")
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()
        let (tileA, tileB) = (try tile(model, 0), try tile(model, 1))

        async let first = model.remove(tileA)
        async let second = model.remove(tileB)
        let (removedA, removedB) = await (first, second)

        XCTAssertFalse(removedA)
        XCTAssertTrue(removedB)
        XCTAssertEqual(model.tiles.map(\.id), ["a", "c"])
        XCTAssertFalse(model.isRemoving(tileA))
    }

    /// Remove A's reload is slow and answers after remove B's: B stays gone.
    func testASlowerEarlierRefreshDoesNotResurrectARemovedTitle() async throws {
        serve([entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2), entryJSON("c", tmdb: 3)])
        JellyfinRouteStub.routes["DELETE \(base)/Items/a"] = (204, "")
        JellyfinRouteStub.routes["DELETE \(base)/Items/b"] = (204, "")
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()
        let (tileA, tileB) = (try tile(model, 0), try tile(model, 1))

        serve([entryJSON("b", tmdb: 2), entryJSON("c", tmdb: 3)]) // after A only
        JellyfinRouteStub.delays["GET \(base)"] = 0.5
        let removeA = Task { await model.remove(tileA) }
        await eventually { JellyfinRouteStub.requests("GET", base).count == 2 }
        JellyfinRouteStub.delays["GET \(base)"] = 0
        serve([entryJSON("c", tmdb: 3)]) // after A and B
        let removedB = await model.remove(tileB)
        let removedA = await removeA.value

        XCTAssertTrue(removedA)
        XCTAssertTrue(removedB)
        XCTAssertEqual(model.tiles.map(\.id), ["c"])
    }

    /// The DELETE worked but the reload after it didn't: the title still goes.
    func testRemoveWhoseRefreshFailsStillDropsTheTile() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON(entries: [entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2)])),
            (500, "")
        ]
        JellyfinRouteStub.routes["DELETE \(base)/Items/a"] = (204, "")
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()

        let removed = await model.remove(try tile(model, 0))

        XCTAssertTrue(removed)
        XCTAssertEqual(model.tiles.map(\.id), ["b"])
        XCTAssertEqual(model.summary, "Private · 1 title")
    }

    func testTappingRemoveTwiceSendsOneDelete() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON(entries: [entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2)])),
            (200, listJSON(entries: [entryJSON("b", tmdb: 2)]))
        ]
        JellyfinRouteStub.routes["DELETE \(base)/Items/a"] = (204, "")
        JellyfinRouteStub.delays["DELETE \(base)/Items/a"] = 0.3
        let model = try makeModel(seerr: signedOutSeerr())
        await model.load()
        let tileA = try tile(model, 0)

        let first = Task { await model.remove(tileA) }
        await eventually { !JellyfinRouteStub.requests("DELETE", "\(base)/Items/a").isEmpty }
        XCTAssertTrue(model.isRemoving(tileA), "dimmed while on its way")
        let second = await model.remove(tileA)
        let firstResult = await first.value

        XCTAssertTrue(firstResult)
        XCTAssertTrue(second, "an ignored tap reports no failure")
        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", "\(base)/Items/a").count, 1)
        XCTAssertEqual(model.tiles.map(\.id), ["b"])
        XCTAssertFalse(model.isRemoving(tileA))
    }
}

// MARK: Lookups across an owner change

extension WatchlistPageViewModelTests {
    func testATitleQueuedAfterTheOwnerChangedIsStillLookedUp() async throws {
        serve([entryJSON("a", tmdb: 1), entryJSON("b", tmdb: 2)])
        let fake = CountingLookup()
        fake.status = 2
        let session = await signedInSeerr()
        let model = try makeModel(seerr: session, lookup: { targets in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return fake(targets)
        })
        await model.load()
        model.tileAppeared(try tile(model, 0)) // a batch is now in flight

        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(id: 8), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        await session.signInLocal(email: "other@example.com", password: "pw")
        try await Task.sleep(nanoseconds: 50_000_000) // the model has seen the new owner
        model.tileAppeared(try tile(model, 1)) // queued behind the stale batch
        await model.waitForLookups()

        XCTAssertEqual(fake.batches.count, 2, "the second title is asked about without another tileAppeared")
        XCTAssertEqual(fake.batches.last?.map(\.tmdbId), [2])
        XCTAssertEqual(try tile(model, 1).missingTag, .requested)
        XCTAssertEqual(try tile(model, 0).missingTag, .notOnServer, "the last person's answer for a is still dropped")
    }
}

/// A lookup that counts how often it's asked and for what, and says `status` for every title.
private final class CountingLookup {
    var batches: [[SeerrTarget]] = []
    var status: Int?
    var asked: [SeerrTarget] { batches.flatMap { $0 } }

    func callAsFunction(_ targets: [SeerrTarget]) -> [String: SeerrMediaInfo?] {
        batches.append(targets)
        var result: [String: SeerrMediaInfo?] = [:]
        for target in targets {
            result.updateValue(status.map { SeerrMediaInfo(status: $0) }, forKey: target.id)
        }
        return result
    }
}
