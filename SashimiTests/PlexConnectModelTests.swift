import XCTest
@testable import Sashimi

/// Connect Plex: plex.tv answers come from SeerrStubServer, the Jellyfin
/// plugin's from JellyfinRouteStub.
@MainActor
final class PlexConnectModelTests: XCTestCase {
    private let plexPath = "/SashimiLists/Watchlist/Plex"
    private var defaults = SeerrFixtures.defaults()

    override func setUp() {
        super.setUp()
        SeerrStubServer.reset()
        JellyfinRouteStub.reset()
        SeerrClient.testURLProtocolClasses = [SeerrStubServer.self]
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        defaults = SeerrFixtures.defaults()
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":null}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":\"plex-token\"}")
    }

    override func tearDown() {
        SeerrClient.testURLProtocolClasses = []
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func model(pinLifetime: Duration = .seconds(15 * 60)) throws -> PlexConnectModel {
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        let store = WatchlistStore(service: WatchlistService(client: client))
        return PlexConnectModel(store: store, defaults: defaults, pollInterval: .zero, pinLifetime: pinLifetime)
    }

    private func connect(_ model: PlexConnectModel) async throws {
        let pin = await model.begin(strong: false)
        await model.complete(pin: try XCTUnwrap(pin))
    }

    private func body(_ index: Int = 0) throws -> [String: Any] {
        let requests = JellyfinRouteStub.requests("POST", plexPath)
        let data = try XCTUnwrap(requests.indices.contains(index) ? requests[index].body : nil)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testConnectShowsTheCodeThenLinks() async throws {
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let model = try model()

        let pin = await model.begin(strong: false)
        XCTAssertEqual(model.state, .awaitingPlex(code: "K7QF"))
        XCTAssertTrue(model.isWaiting)

        await model.complete(pin: try XCTUnwrap(pin))

        XCTAssertEqual(model.state, .linked)
        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v2/pins/42").count, 2)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
        XCTAssertEqual(try body()["replace"] as? Bool, false)
        XCTAssertTrue(SeerrStubServer.requests("POST", "/api/v1/auth/plex").isEmpty, "Connect Plex never touches Requests")
    }

    func testConnectToAnotherAccountAsksBeforeReplacing() async throws {
        JellyfinRouteStub.sequences["POST \(plexPath)"] = [
            (409, "{\"username\":\"marge\",\"newUsername\":\"homer\"}"),
            (200, "{\"username\":\"homer\",\"needsReconnect\":false}")
        ]
        let model = try model()

        try await connect(model)
        XCTAssertEqual(model.state, .conflict(currentUsername: "marge", newUsername: "homer"))
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)

        await model.confirmSwitch()

        XCTAssertEqual(model.state, .linked)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 2)
        XCTAssertEqual(try body(1)["replace"] as? Bool, true)
    }

    func testARejectedTokenFailsWithAMessage() async throws {
        JellyfinRouteStub.routes["POST \(plexPath)"] = (422, "")
        let model = try model()
        try await connect(model)
        XCTAssertEqual(model.state, .failed("Plex didn't accept that sign-in. Try again."))
    }

    func testPlexUnreachableFailsWithAMessage() async throws {
        JellyfinRouteStub.routes["POST \(plexPath)"] = (503, "")
        let model = try model()
        try await connect(model)
        XCTAssertEqual(model.state, .failed(WatchlistText.couldntReachPlex))
    }

    func testAnUnreachableServerFailsWithAMessage() async throws {
        let model = try model() // no route: the plugin answers 404, which is no verdict
        try await connect(model)
        XCTAssertEqual(model.state, .failed("Couldn't reach your server. Try again."))
    }

    func testAnExpiredCodeFailsWithAMessage() async throws {
        SeerrStubServer.reset()
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":null}")
        let model = try model(pinLifetime: .milliseconds(50))

        try await connect(model)

        XCTAssertEqual(model.state, .failed("The Plex code expired. Try again."))
        XCTAssertTrue(JellyfinRouteStub.requests("POST", plexPath).isEmpty)
    }

    func testCancelGoesBackToIdle() async throws {
        let model = try model()
        _ = await model.begin(strong: false)
        XCTAssertEqual(model.state, .awaitingPlex(code: "K7QF"))

        model.cancel()

        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(model.isWaiting)
    }

    /// Requests never set up on this device: no Seerr address, no session.
    func testConnectWorksWithNoSeerrServerConfigured() async throws {
        let name = "plex-connect-no-seerr-\(UUID().uuidString)"
        let empty = try XCTUnwrap(UserDefaults(suiteName: name))
        empty.removePersistentDomain(forName: name)
        defer { empty.removePersistentDomain(forName: name) }
        XCTAssertTrue(empty.dictionaryRepresentation().keys.filter { $0.hasPrefix("seerr.") }.isEmpty)
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        let model = PlexConnectModel(store: WatchlistStore(service: WatchlistService(client: client)),
                                     defaults: empty, pollInterval: .zero)

        let pin = await model.begin(strong: true)
        XCTAssertEqual(model.state, .awaitingPlex(code: "K7QF"))
        await model.complete(pin: try XCTUnwrap(pin))

        XCTAssertEqual(model.state, .linked)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
    }

    func testConnectUsesTheSameClientIdentifierAsRequests() async throws {
        let session = SeerrSession(defaults: defaults, credentials: InMemorySeerrCredentials(), pollInterval: .zero)
        _ = session.setServerAddress(SeerrFixtures.server.absoluteString)
        _ = await session.beginPlexSignIn(strong: false)
        let requestsId = try XCTUnwrap(SeerrStubServer.requests("POST", "/api/v2/pins").last?.headers["X-Plex-Client-Identifier"])

        let model = try model()
        _ = await model.begin(strong: false)

        let connectId = SeerrStubServer.requests("POST", "/api/v2/pins").last?.headers["X-Plex-Client-Identifier"]
        XCTAssertEqual(connectId, requestsId)
        XCTAssertEqual(defaults.string(forKey: "seerr.plexClientIdentifier"), requestsId)
    }
}
