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

    private func model(pinLifetime: Duration = .seconds(15 * 60), now: @escaping () -> Date = Date.init,
                       server: String = "http://stub.local", user: String = "me") throws -> PlexConnectModel {
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: server)), accessToken: "token", userId: user)
        let store = WatchlistStore(service: WatchlistService(client: client))
        return PlexConnectModel(store: store, defaults: defaults, pollInterval: .zero, pinLifetime: pinLifetime, now: now)
    }

    /// The saved pending PIN, as stored.
    private func pendingRecord() -> [String: Any]? {
        guard let data = defaults.data(forKey: PlexConnectModel.pendingPinKey) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// plex.tv answers every check of PIN 42 with the token.
    private func pinAlwaysLinked() {
        SeerrStubServer.reset()
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":\"plex-token\"}")
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

    // MARK: Suspend and relaunch

    /// The app was suspended past the PIN's deadline while the person linked
    /// it: one last check still collects the token.
    func testAPinLinkedJustBeforeTheDeadlineStillLinks() async throws {
        pinAlwaysLinked()
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let model = try model(pinLifetime: .zero)

        try await connect(model)

        XCTAssertEqual(model.state, .linked)
        XCTAssertGreaterThanOrEqual(SeerrStubServer.requests("GET", "/api/v2/pins/42").count, 1)
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
    }

    /// The app was killed while the person was on Plex's page: on the next
    /// launch the saved PIN is checked once and the Watchlist linked.
    func testAPinFromBeforeARelaunchIsCollected() async throws {
        let before = try model()
        _ = await before.begin(strong: true)
        XCTAssertNotNil(pendingRecord(), "the PIN is saved while it waits")

        pinAlwaysLinked()
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        let relaunched = try model()
        await relaunched.resumePendingIfAny()

        XCTAssertEqual(relaunched.state, .linked)
        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v2/pins/42").count, 1, "one check, no long poll")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1)
        XCTAssertEqual(try body()["replace"] as? Bool, false)
        XCTAssertNil(pendingRecord(), "collected: nothing left to resume")

        try await model().resumePendingIfAny()
        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1, "never linked twice")
    }

    /// Relaunched into another account's link: the switch question, with the
    /// PIN kept until it's answered.
    func testAResumedPinThatFindsAnotherAccountAsks() async throws {
        _ = try await model().begin(strong: true)
        pinAlwaysLinked()
        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"marge\",\"newUsername\":\"homer\"}")
        let relaunched = try model()

        await relaunched.resumePendingIfAny()

        XCTAssertEqual(relaunched.state, .conflict(currentUsername: "marge", newUsername: "homer"))
        XCTAssertNotNil(pendingRecord(), "not answered yet")
        relaunched.cancel()
        XCTAssertNil(pendingRecord(), "answered: Keep")
    }

    func testAnExpiredPendingPinIsDropped() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await model(now: { start }).begin(strong: true)
        XCTAssertNotNil(pendingRecord())
        SeerrStubServer.reset()

        let relaunched = try model(now: { start.addingTimeInterval(16 * 60) })
        await relaunched.resumePendingIfAny()

        XCTAssertEqual(relaunched.state, .idle)
        XCTAssertTrue(SeerrStubServer.requests("GET", "/api/v2/pins/42").isEmpty, "an expired PIN isn't checked")
        XCTAssertNil(pendingRecord())
    }

    /// Someone else signed in after the relaunch: the PIN isn't theirs to
    /// collect. It is dropped without asking plex.tv.
    func testAPendingPinFromAnotherUserIsDropped() async throws {
        _ = try await model(user: "me").begin(strong: true)
        XCTAssertNotNil(pendingRecord())
        pinAlwaysLinked()
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")

        let relaunched = try model(user: "someone-else")
        await relaunched.resumePendingIfAny()

        XCTAssertEqual(relaunched.state, .idle)
        XCTAssertTrue(SeerrStubServer.requests("GET", "/api/v2/pins/42").isEmpty, "no network call")
        XCTAssertTrue(JellyfinRouteStub.requests("POST", plexPath).isEmpty)
        XCTAssertNil(pendingRecord())
    }

    /// The same user id on another server is another account.
    func testAPendingPinFromAnotherServerIsDropped() async throws {
        _ = try await model(server: "http://stub.local").begin(strong: true)
        XCTAssertNotNil(pendingRecord())
        pinAlwaysLinked()
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")

        let relaunched = try model(server: "http://other.local")
        await relaunched.resumePendingIfAny()

        XCTAssertEqual(relaunched.state, .idle)
        XCTAssertTrue(SeerrStubServer.requests("GET", "/api/v2/pins/42").isEmpty, "no network call")
        XCTAssertTrue(JellyfinRouteStub.requests("POST", plexPath).isEmpty)
        XCTAssertNil(pendingRecord())
    }

    func testThePendingPinNeverStoresTheToken() async throws {
        pinAlwaysLinked()
        JellyfinRouteStub.routes["POST \(plexPath)"] = (409, "{\"username\":\"marge\",\"newUsername\":\"homer\"}")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let model = try model(now: { start })

        let pin = await model.begin(strong: true)
        let record = try XCTUnwrap(pendingRecord())
        XCTAssertEqual(Set(record.keys), ["pinId", "code", "expiresAt", "userId", "serverURL"])
        XCTAssertEqual(record["userId"] as? String, "me")
        XCTAssertEqual(record["serverURL"] as? String, "http://stub.local")
        XCTAssertEqual(record["pinId"] as? Int, 42)
        XCTAssertEqual(record["code"] as? String, "K7QF")

        await model.complete(pin: try XCTUnwrap(pin))
        XCTAssertEqual(model.state, .conflict(currentUsername: "marge", newUsername: "homer"), "the token is held now")

        XCTAssertNotNil(pendingRecord())
        for (key, value) in defaults.dictionaryRepresentation() {
            let text = (value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
            XCTAssertFalse(text.contains("plex-token"), "the token was written under \(key)")
        }
    }

    /// Every end of a Connect Plex leaves no PIN to resume.
    func testEveryEndClearsThePendingPin() async throws {
        let ends: [(String, () async throws -> Void)] = [
            ("linked", { JellyfinRouteStub.routes["POST \(self.plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}") }),
            ("rejected", { JellyfinRouteStub.routes["POST \(self.plexPath)"] = (422, "") }),
            ("unreachable", { JellyfinRouteStub.routes["POST \(self.plexPath)"] = (503, "") })
        ]
        for (name, arrange) in ends {
            pinAlwaysLinked()
            try await arrange()
            let model = try model()
            let pin = await model.begin(strong: true)
            XCTAssertNotNil(pendingRecord(), name)
            await model.complete(pin: try XCTUnwrap(pin))
            XCTAssertNil(pendingRecord(), name)
        }

        SeerrStubServer.reset()
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":null}")
        let expiring = try model(pinLifetime: .milliseconds(20))
        let pin = await expiring.begin(strong: true)
        XCTAssertNotNil(pendingRecord(), "expired")
        await expiring.complete(pin: try XCTUnwrap(pin))
        XCTAssertNil(pendingRecord(), "expired")

        let cancelled = try model()
        _ = await cancelled.begin(strong: true)
        XCTAssertNotNil(pendingRecord(), "cancelled")
        cancelled.cancel()
        XCTAssertNil(pendingRecord(), "cancelled")
    }

    // MARK: Progress and messages

    func testProgressTextSaysWhatTheConnectIsWaitingOn() async throws {
        JellyfinRouteStub.routes["POST \(plexPath)"] = (200, "{\"username\":\"marge\",\"needsReconnect\":false}")
        JellyfinRouteStub.delays["POST \(plexPath)"] = 0.3
        let model = try model()
        XCTAssertNil(model.progressText)

        let begun = await model.begin(strong: true)
        let pin = try XCTUnwrap(begun)
        XCTAssertEqual(model.progressText, "Waiting for Plex…")

        let completing = Task { await model.complete(pin: pin) }
        for _ in 0..<200 where model.state != .linking { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.state, .linking)
        XCTAssertEqual(model.progressText, "Connecting…")

        await completing.value
        XCTAssertEqual(model.state, .linked)
        XCTAssertNil(model.progressText)
    }

    /// "Switch" couldn't reach Plex: the question comes back with a reason,
    /// not silently.
    func testAFailedSwitchSaysPlexCouldntBeReached() async throws {
        JellyfinRouteStub.sequences["POST \(plexPath)"] = [
            (409, "{\"username\":\"marge\",\"newUsername\":\"homer\"}"),
            (503, ""),
            (200, "{\"username\":\"homer\",\"needsReconnect\":false}")
        ]
        let model = try model()
        try await connect(model)
        XCTAssertNil(model.message)

        await model.confirmSwitch()

        XCTAssertEqual(model.state, .conflict(currentUsername: "marge", newUsername: "homer"))
        XCTAssertEqual(model.message, WatchlistText.couldntReachPlex)

        await model.confirmSwitch()
        XCTAssertEqual(model.state, .linked)
        XCTAssertNil(model.message, "a new answer clears it")
    }

    /// Cancel while plex.tv is still making the code: it stays cancelled, and
    /// nothing is saved to resume.
    func testCancelWhileTheCodeIsBeingFetchedStaysCancelled() async throws {
        SeerrStubServer.delays["POST /api/v2/pins"] = 0.3
        let model = try model()
        let beginning = Task { await model.begin(strong: true) }
        for _ in 0..<200 where SeerrStubServer.requests("POST", "/api/v2/pins").isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        model.cancel()
        let pin = await beginning.value

        XCTAssertNil(pin)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(pendingRecord())
    }

    /// The switch question was asked for this user; after a switch to another
    /// one, "Switch" sends nothing and the question goes away.
    func testAHeldTokenIsNotSentForAnotherUser() async throws {
        JellyfinRouteStub.sequences["POST \(plexPath)"] = [
            (409, "{\"username\":\"marge\",\"newUsername\":\"homer\"}"),
            (200, "{\"username\":\"homer\",\"needsReconnect\":false}")
        ]
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        let model = PlexConnectModel(store: WatchlistStore(service: WatchlistService(client: client)),
                                     defaults: defaults, pollInterval: .zero)
        try await connect(model)
        XCTAssertEqual(model.state, .conflict(currentUsername: "marge", newUsername: "homer"))

        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "other")
        await model.confirmSwitch()

        XCTAssertEqual(JellyfinRouteStub.requests("POST", plexPath).count, 1, "nothing sent for the other user")
        XCTAssertEqual(model.state, .idle)
    }
}

