import XCTest
@testable import Sashimi

/// The Watchlist store against a stubbed server.
@MainActor
final class WatchlistStoreTests: XCTestCase {
    private let base = "/SashimiLists/Watchlist"
    private let plexPath = "/SashimiLists/Watchlist/Plex"

    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client(user: String = "me") throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: user)
    }

    private func store(_ client: JellyfinClient) -> WatchlistStore {
        WatchlistStore(service: WatchlistService(client: client))
    }

    private func entryJSON(id: String = "e1") -> String {
        "{\"id\":\"\(id)\",\"type\":\"Movie\",\"title\":\"Heat\",\"year\":1995,\"tmdbId\":\"949\"}"
    }

    private func listJSON(plex: String? = nil, entries: [String] = [], optedOut: Bool = false) -> String {
        let plexPart = plex.map { "\"plex\":{\"username\":\"\($0)\",\"needsReconnect\":false}," } ?? ""
        let optedOutPart = optedOut ? "\"plexOptedOut\":true," : ""
        return "{\(plexPart)\(optedOutPart)\"cardDismissed\":false,\"entries\":[\(entries.joined(separator: ","))]}"
    }

    private func movie(providerIds: String? = "{\"Tmdb\":\"949\"}") throws -> BaseItemDto {
        let ids = providerIds.map { ",\"ProviderIds\":\($0)" } ?? ""
        let json = "{\"Id\":\"m1\",\"Name\":\"Heat\",\"Type\":\"Movie\",\"ProductionYear\":1995\(ids)}"
        return try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    private func posted(_ index: Int) throws -> [String: Any] {
        let requests = JellyfinRouteStub.requests("POST", plexPath)
        let body = try XCTUnwrap(requests.indices.contains(index) ? requests[index].body : nil)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testNoRouteMeansUnavailable() async throws {
        let store = store(try client())
        await store.refresh()
        XCTAssertEqual(store.availability, .unavailable)
        XCTAssertFalse(store.isAvailable)
        XCTAssertNil(store.watchlist)
    }

    func testARouteMeansAvailable() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(entries: [entryJSON()]))
        let store = store(try client())
        await store.refresh()
        XCTAssertEqual(store.availability, .available)
        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(store.watchlist?.entries.map(\.id), ["e1"])
        XCTAssertTrue(store.contains(WatchlistIds(tmdb: "949"), kind: .movie))
        XCTAssertFalse(store.contains(WatchlistIds(tmdb: "1"), kind: .movie))
    }

    func testANetworkErrorAfterALoadKeepsTheWatchlist() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON(entries: [entryJSON()])), (400, "")]
        let store = store(try client())
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.availability, .available)
        XCTAssertEqual(store.watchlist?.entries.map(\.id), ["e1"])
    }

    func testAnotherUserSeesNothingOfTheLastOnesWatchlist() async throws {
        let client = try client(user: "a")
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge", entries: [entryJSON()]))
        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"marge\",\"newUsername\":\"chad\"}")
        let store = store(client)
        await store.autoLink(token: "T")
        XCTAssertNotNil(store.pendingSwitch)
        XCTAssertNotNil(store.watchlist)

        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "b")
        JellyfinRouteStub.routes["GET \(base)"] = (404, "")
        await store.refresh()
        XCTAssertNil(store.watchlist)
        XCTAssertNil(store.pendingSwitch)
        XCTAssertEqual(store.availability, .unavailable)
        // The held token went with it: nothing to confirm.
        let posts = JellyfinRouteStub.requests("POST", plexPath).count
        _ = await store.confirmSwitch()
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, posts)
    }

    func testAutoLinkSkipsSomeoneWhoDisconnectedPlex() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(optedOut: true))
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let store = store(try client())
        await store.autoLink(token: "T")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 0)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.watchlist?.plex)
    }

    func testAnExplicitConnectStillLinksAfterOptingOut() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON(optedOut: true)), (200, listJSON(plex: "marge"))]
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let store = store(try client())
        await store.refresh()
        let result = await store.link(token: "T", replace: false)
        XCTAssertEqual(result, .linked(PlexLink(username: "marge", needsReconnect: false)))
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
    }

    func testAutoLinkWhenNotLinkedLinksAndSaysSo() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON()), (200, listJSON(plex: "marge"))]
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let store = store(try client())
        await store.autoLink(token: "T")
        XCTAssertEqual(store.notice, "Your Watchlist now syncs with Plex")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
        XCTAssertEqual(try posted(0)["replace"] as? Bool, false)
        XCTAssertEqual(try posted(0)["token"] as? String, "T")
        XCTAssertEqual(store.watchlist?.plex?.username, "marge")
    }

    func testAutoLinkToTheSameAccountIsSilent() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge"))
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let store = store(try client())
        await store.autoLink(token: "T")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.pendingSwitch)
    }

    func testAutoLinkToAnotherAccountAsksAndOnlyReplacesOnYes() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge"))
        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"marge\",\"newUsername\":\"chad\"}")
        let store = store(try client())
        await store.autoLink(token: "T")
        XCTAssertEqual(store.pendingSwitch?.currentUsername, "marge")
        XCTAssertEqual(store.pendingSwitch?.newUsername, "chad")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
        XCTAssertEqual(try posted(0)["replace"] as? Bool, false)

        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"chad\",\"needsReconnect\":false}")
        let switched = await store.confirmSwitch()
        XCTAssertTrue(switched)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 2)
        XCTAssertEqual(try posted(1)["replace"] as? Bool, true)
        XCTAssertEqual(try posted(1)["token"] as? String, "T")
        XCTAssertNil(store.pendingSwitch)
    }

    func testDecliningTheSwitchSendsNothingMore() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge"))
        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"marge\",\"newUsername\":\"chad\"}")
        let store = store(try client())
        await store.autoLink(token: "T")
        store.declineSwitch()
        XCTAssertNil(store.pendingSwitch)
        let switched = await store.confirmSwitch()
        XCTAssertFalse(switched)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
    }

    func testAutoLinkDoesNothingWithoutTheWatchlistPlugin() async throws {
        let store = store(try client())
        await store.autoLink(token: "T")
        XCTAssertTrue(JellyfinRouteStub.requests("POST", plexPath).isEmpty)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.pendingSwitch)
    }

    func testAddMessages() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON())
        let store = store(try client())
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"entry\":\(entryJSON()),\"added\":true}")
        var message = await store.add(try movie())
        XCTAssertEqual(message, "Added to Watchlist")
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"entry\":\(entryJSON()),\"added\":false}")
        message = await store.add(try movie())
        XCTAssertEqual(message, "Already on your Watchlist")
        message = await store.add(try movie(providerIds: nil))
        XCTAssertEqual(message, WatchlistError.notEligible.localizedDescription)
        JellyfinRouteStub.routes["POST \(base)/Items"] = (500, "")
        message = await store.add(try movie())
        XCTAssertEqual(message, "Couldn't add to Watchlist")
    }

    func testAddRefreshesTheWatchlist() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON()), (200, listJSON(entries: [entryJSON()]))]
        JellyfinRouteStub.routes["POST \(base)/Items"] = (200, "{\"entry\":\(entryJSON()),\"added\":true}")
        let store = store(try client())
        await store.refresh()
        _ = await store.add(try movie())
        XCTAssertEqual(store.watchlist?.entries.map(\.id), ["e1"])
    }

    func testAutoLinkIsSilentWhenPlexIsUnreachable() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON())
        JellyfinRouteStub.routes["POST \(plexPath)"] = (503, "{}")
        let store = store(try client())
        await store.autoLink(token: "T")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
        XCTAssertNil(store.notice)
        XCTAssertNil(store.pendingSwitch)
    }

    /// User A holds a Watchlist and a pending switch; returns the store and client.
    private func storeWithAPendingSwitch() async throws -> (WatchlistStore, JellyfinClient) {
        let client = try client(user: "a")
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge", entries: [entryJSON()]))
        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"marge\",\"newUsername\":\"chad\"}")
        let store = store(client)
        await store.autoLink(token: "T")
        XCTAssertNotNil(store.pendingSwitch)
        XCTAssertNotNil(store.watchlist)
        return (store, client)
    }

    func testAnotherUserWhoseLoadFailsSeesNothingOfTheLastOnes() async throws {
        let (store, client) = try await storeWithAPendingSwitch()
        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "b")
        JellyfinRouteStub.routes["GET \(base)"] = (400, "") // a failed load (not retried, unlike a 5xx)
        await store.refresh()
        XCTAssertNil(store.watchlist)
        XCTAssertEqual(store.availability, .unknown)
        XCTAssertNil(store.pendingSwitch)
    }

    func testAnotherServerSeesNothingOfTheLastOnes() async throws {
        let (store, client) = try await storeWithAPendingSwitch()
        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://other.local")), accessToken: "token", userId: "a")
        JellyfinRouteStub.routes["GET \(base)"] = (400, "") // a failed load (not retried, unlike a 5xx)
        await store.refresh()
        XCTAssertNil(store.watchlist)
        XCTAssertEqual(store.availability, .unknown)
        XCTAssertNil(store.pendingSwitch)
    }

    func testAResultForThePreviousUserIsDiscarded() async throws {
        let client = try client(user: "a")
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge"))
        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"marge\",\"newUsername\":\"chad\"}")
        JellyfinRouteStub.delays["POST \(plexPath)"] = 0.5
        let store = store(client)
        let pending = Task { await store.autoLink(token: "T") }
        // The link call is in flight (and held by the stub): the user changes under it.
        for _ in 0..<200 where JellyfinRouteStub.requests("POST", plexPath).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "b")
        await pending.value
        XCTAssertNil(store.pendingSwitch, "user B must not be asked about user A's Plex token")
        XCTAssertNil(store.notice)
        let posts = JellyfinRouteStub.requests("POST", plexPath).count
        let switched = await store.confirmSwitch()
        XCTAssertFalse(switched)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, posts, "no token was held")
    }

    func testConfirmSwitchKeepsTheQuestionWhenTheServerCantBeReached() async throws {
        let (store, _) = try await storeWithAPendingSwitch()
        let question = try XCTUnwrap(store.pendingSwitch)
        // 503: Plex unreachable. 403: the call itself failed (nil).
        for status in [503, 403] {
            JellyfinRouteStub.routes["POST \(plexPath)"] = (status, "{}")
            let switched = await store.confirmSwitch()
            XCTAssertFalse(switched, "status \(status)")
            XCTAssertEqual(store.pendingSwitch, question, "status \(status)")
        }
        // Still answerable: the held token is still there.
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"chad\",\"needsReconnect\":false}")
        let switched = await store.confirmSwitch()
        XCTAssertTrue(switched)
        XCTAssertNil(store.pendingSwitch)
        XCTAssertEqual(try posted(3)["token"] as? String, "T")
        XCTAssertEqual(try posted(3)["replace"] as? Bool, true)
    }

    func testARefreshForThePreviousUserIsDiscarded() async throws {
        let client = try client(user: "a")
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge", entries: [entryJSON()]))
        JellyfinRouteStub.delays["GET \(base)"] = 0.5
        let store = store(client)
        let pending = Task { await store.refresh() }
        for _ in 0..<200 where JellyfinRouteStub.requests("GET", base).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(JellyfinRouteStub.requests("GET", base).count, 1)
        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "b")
        await pending.value
        XCTAssertNil(store.watchlist, "user B must not see user A's list")
        XCTAssertNotEqual(store.availability, .available)
    }

    /// A slow load (the page opening) that answers after a newer one (a link's)
    /// would put the old Watchlist back: only the latest load lands.
    func testOlderRefreshCannotOverwriteANewerOne() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(entries: [entryJSON()]))
        JellyfinRouteStub.delays["GET \(base)"] = 0.5
        let store = store(try client())
        let slow = Task { await store.refresh() }
        for _ in 0..<200 where JellyfinRouteStub.requests("GET", base).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        JellyfinRouteStub.delays["GET \(base)"] = 0
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge", entries: [entryJSON(), entryJSON(id: "e2")]))

        await store.refresh()
        XCTAssertEqual(store.watchlist?.plex?.username, "marge")
        await slow.value

        XCTAssertEqual(store.watchlist?.plex?.username, "marge", "the older answer landed last and won")
        XCTAssertEqual(store.watchlist?.entries.map(\.id), ["e1", "e2"])
    }

    /// "Switch" in Settings › Requests couldn't reach Plex: the question comes
    /// back with a reason, not silently.
    func testAFailedSwitchSaysPlexCouldntBeReached() async throws {
        let (store, _) = try await storeWithAPendingSwitch()
        XCTAssertNil(store.switchFailure)
        JellyfinRouteStub.routes["POST \(plexPath)"] = (503, "{}")

        let failed = await store.confirmSwitch()

        XCTAssertFalse(failed)
        XCTAssertNotNil(store.pendingSwitch)
        XCTAssertEqual(store.switchFailure, WatchlistText.couldntReachPlex)

        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"chad\",\"needsReconnect\":false}")
        let switched = await store.confirmSwitch()
        XCTAssertTrue(switched)
        XCTAssertNil(store.switchFailure)

        // "Keep" after a failed "Switch" takes the reason away with the question.
        let (other, _) = try await storeWithAPendingSwitch()
        JellyfinRouteStub.routes["POST \(plexPath)"] = (503, "{}")
        _ = await other.confirmSwitch()
        XCTAssertEqual(other.switchFailure, WatchlistText.couldntReachPlex)
        other.declineSwitch()
        XCTAssertNil(other.switchFailure)
        XCTAssertNil(other.pendingSwitch)
    }

    /// A slow load whose newer one then fails is still the best answer there
    /// is: its caller sees the Watchlist, not an unloaded store.
    func testASlowRefreshStillLandsWhenANewerOneFails() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge", entries: [entryJSON()]))
        JellyfinRouteStub.delays["GET \(base)"] = 0.5
        let store = store(try client())
        let slow = Task { () -> (WatchlistStore.Availability, [String]?) in
            await store.refresh()
            return (store.availability, store.watchlist?.entries.map(\.id))
        }
        for _ in 0..<200 where JellyfinRouteStub.requests("GET", base).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        JellyfinRouteStub.delays["GET \(base)"] = 0
        JellyfinRouteStub.routes["GET \(base)"] = (200, "not json") // the newer load fails

        await store.refresh()
        let (availability, ids) = await slow.value

        XCTAssertEqual(availability, .available)
        XCTAssertEqual(ids, ["e1"])
        XCTAssertEqual(store.watchlist?.plex?.username, "marge")
    }

    /// The newer load is still on its way when the older one answers: the
    /// older one lands for its caller, and the newer one replaces it after.
    func testASlowRefreshLandsWhileANewerOneIsStillOnItsWay() async throws {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(entries: [entryJSON()]))
        JellyfinRouteStub.delays["GET \(base)"] = 0.3
        let store = store(try client())
        let first = Task { () -> [String]? in
            await store.refresh()
            return store.watchlist?.entries.map(\.id)
        }
        for _ in 0..<200 where JellyfinRouteStub.requests("GET", base).isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        JellyfinRouteStub.delays["GET \(base)"] = 1.0
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: "marge", entries: [entryJSON(), entryJSON(id: "e2")]))
        let second = Task { await store.refresh() }
        for _ in 0..<200 where JellyfinRouteStub.requests("GET", base).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstSaw = await first.value
        XCTAssertEqual(firstSaw, ["e1"])
        XCTAssertEqual(store.availability, .available)

        await second.value
        XCTAssertEqual(store.watchlist?.entries.map(\.id), ["e1", "e2"])
    }
}
