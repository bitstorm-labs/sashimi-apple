import Combine
import XCTest
@testable import Sashimi

/// The Settings › Plex row model, over the same store the Watchlist page uses.
@MainActor
final class PlexSettingsModelTests: XCTestCase {
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

    private func makeStore() throws -> WatchlistStore {
        let client = JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        return WatchlistStore(service: WatchlistService(client: client))
    }

    private func listJSON(plex: String? = nil, needsReconnect: Bool = false, dismissed: Bool = false) -> String {
        let plexPart = plex.map { "\"plex\":{\"username\":\"\($0)\",\"needsReconnect\":\(needsReconnect)}," } ?? ""
        return "{\(plexPart)\"cardDismissed\":\(dismissed),\"entries\":[]}"
    }

    private func serve(plex: String? = nil, needsReconnect: Bool = false, dismissed: Bool = false) {
        JellyfinRouteStub.routes["GET \(base)"] = (200, listJSON(plex: plex, needsReconnect: needsReconnect, dismissed: dismissed))
    }

    func testHiddenWithoutTheWatchlistPlugin() async throws {
        let model = PlexSettingsModel(store: try makeStore())
        await model.load()
        XCTAssertEqual(model.row, .hidden)
        XCTAssertEqual(model.actions, [])
    }

    func testNotConnectedOffersConnect() async throws {
        serve()
        let model = PlexSettingsModel(store: try makeStore())
        await model.load()
        XCTAssertEqual(model.row, .notConnected)
        XCTAssertEqual(model.status, "Not connected")
        XCTAssertEqual(model.actions, [.connect])
        XCTAssertEqual(model.footer, "Keeps your Watchlist in sync with your Plex watchlist.")
    }

    func testConnectedShowsTheUsernameAndOffersDisconnect() async throws {
        serve(plex: "chad")
        let model = PlexSettingsModel(store: try makeStore())
        await model.load()
        XCTAssertEqual(model.row, .connected(username: "chad"))
        XCTAssertEqual(model.status, "Connected as chad")
        XCTAssertEqual(model.actions, [.disconnect])
    }

    func testNeedsReconnectOffersReconnectAndDisconnect() async throws {
        serve(plex: "chad", needsReconnect: true)
        let model = PlexSettingsModel(store: try makeStore())
        await model.load()
        XCTAssertEqual(model.row, .needsReconnect(username: "chad"))
        XCTAssertEqual(model.status, "Connected as chad")
        XCTAssertEqual(model.actions, [.reconnect, .disconnect])
    }

    func testActionTitlesAreTheFixedCopy() {
        XCTAssertEqual(PlexSettingsModel.Action.connect.title, "Connect Plex")
        XCTAssertEqual(PlexSettingsModel.Action.reconnect.title, "Reconnect Plex")
        XCTAssertEqual(PlexSettingsModel.Action.disconnect.title, "Disconnect Plex")
    }

    func testSummarySaysTheStatusThenWhatSelectingDoes() async throws {
        serve()
        let notConnected = PlexSettingsModel(store: try makeStore())
        await notConnected.load()
        XCTAssertEqual(notConnected.summary, "Not connected · Connect Plex")

        serve(plex: "chad")
        let connected = PlexSettingsModel(store: try makeStore())
        await connected.load()
        XCTAssertEqual(connected.summary, "Connected as chad · Disconnect Plex")

        serve(plex: "chad", needsReconnect: true)
        let stale = PlexSettingsModel(store: try makeStore())
        await stale.load()
        XCTAssertEqual(stale.summary, "Connected as chad · Reconnect Plex")
    }

    func testSummaryIsEmptyWhenHidden() async throws {
        let model = PlexSettingsModel(store: try makeStore())
        await model.load()
        XCTAssertEqual(model.summary, "")
    }

    func testDisconnectUnlinksAndShowsNotConnected() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON(plex: "chad")), (200, listJSON())]
        JellyfinRouteStub.routes["DELETE \(plexPath)"] = (204, "")
        let model = PlexSettingsModel(store: try makeStore())
        await model.load()
        XCTAssertEqual(model.row, .connected(username: "chad"))

        let done = await model.disconnect()

        XCTAssertTrue(done)
        XCTAssertEqual(JellyfinRouteStub.requests("DELETE", plexPath).count, 1)
        XCTAssertEqual(model.row, .notConnected)
    }

    func testLinkingFromTheWatchlistUpdatesSettings() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON()), (200, listJSON(plex: "chad"))]
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"chad\",\"needsReconnect\":false}")
        let store = try makeStore()
        let model = PlexSettingsModel(store: store)
        await model.load()
        XCTAssertEqual(model.row, .notConnected)

        let result = await store.link(token: "T", replace: false)

        XCTAssertEqual(result, .linked(PlexLink(username: "chad", needsReconnect: false)))
        XCTAssertEqual(model.row, .connected(username: "chad"), "no load() on the settings model")
    }

    func testDisconnectingFromSettingsUpdatesTheWatchlistPage() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [(200, listJSON(plex: "chad")), (200, listJSON())]
        JellyfinRouteStub.routes["DELETE \(plexPath)"] = (204, "")
        let store = try makeStore()
        let page = WatchlistPageViewModel(store: store, service: WatchlistService(client: JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")))
        let settings = PlexSettingsModel(store: store)
        await page.load()
        XCTAssertEqual(page.header, .synced)
        XCTAssertEqual(page.menuItems, [.disconnectPlex])

        var changes = 0
        let watch = page.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        _ = await settings.disconnect()

        XCTAssertGreaterThan(changes, 0, "the page redraws")
        XCTAssertEqual(page.header, .connectCard)
        XCTAssertEqual(page.menuItems, [.connectPlex])
    }

    /// Every way the link changes reaches the row without a load() of its own.
    func testSettingsRowFollowsConnectSwitchDisconnectAndQuietRelink() async throws {
        JellyfinRouteStub.sequences["GET \(base)"] = [
            (200, listJSON()),
            (200, listJSON(plex: "chad")),                       // after Connect
            (200, listJSON(plex: "homer")),                      // after Switch
            (200, listJSON()),                                   // after Disconnect
            (200, listJSON(plex: "homer", needsReconnect: true)), // Plex stopped syncing
            (200, listJSON(plex: "homer"))                       // after the quiet relink
        ]
        let store = try makeStore()
        let model = PlexSettingsModel(store: store)
        await model.load()
        XCTAssertEqual(model.row, .notConnected)

        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"chad\",\"needsReconnect\":false}")
        _ = await store.link(token: "T1", replace: false)
        XCTAssertEqual(model.row, .connected(username: "chad"), "Connect")

        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"chad\",\"newUsername\":\"homer\"}")
        await store.autoLink(token: "T2")
        XCTAssertNotNil(store.pendingSwitch)
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"homer\",\"needsReconnect\":false}")
        let switched = await store.confirmSwitch()
        XCTAssertTrue(switched)
        XCTAssertEqual(model.row, .connected(username: "homer"), "Switch")

        JellyfinRouteStub.routes["DELETE \(plexPath)"] = (204, "")
        let unlinked = await store.unlink()
        XCTAssertTrue(unlinked)
        XCTAssertEqual(model.row, .notConnected, "Disconnect")

        await store.refresh()
        XCTAssertEqual(model.row, .needsReconnect(username: "homer"))
        await store.autoLink(token: "T2")
        XCTAssertEqual(model.row, .connected(username: "homer"), "quiet relink")
        XCTAssertNil(store.notice, "the same account relinks silently")
    }
}
