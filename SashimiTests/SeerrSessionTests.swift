import XCTest
@testable import Sashimi

/// Signing in to Seerr and staying signed in: the states Settings › Requests
/// shows, and that the rest of the app keys off (no account, no request UI).
@MainActor
final class SeerrSessionTests: XCTestCase {
    private var credentials = InMemorySeerrCredentials()
    private var defaults = SeerrFixtures.defaults()

    override func setUp() {
        super.setUp()
        SeerrStubServer.reset()
        SeerrClient.testURLProtocolClasses = [SeerrStubServer.self]
        credentials = InMemorySeerrCredentials()
        defaults = SeerrFixtures.defaults()
    }

    override func tearDown() {
        SeerrClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func session() -> SeerrSession {
        let session = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)
        _ = session.setServerAddress(SeerrFixtures.server.absoluteString)
        return session
    }

    private var cookieKey: String { SeerrSession.cookieKey(for: SeerrFixtures.server) }

    func testANewInstallHasNoServerAndStaysOffTheNetwork() async {
        let session = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)

        XCTAssertEqual(session.state, .notConfigured)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.client)
        XCTAssertNil(session.serverURL)
        XCTAssertFalse(session.canSignIn)

        await session.restore()
        await session.refreshPublicSettings()
        await session.signInLocal(email: "mom@example.com", password: "pw")
        let pin = await session.beginPlexSignIn(strong: false)

        XCTAssertNil(pin)
        XCTAssertEqual(session.state, .notConfigured)
        XCTAssertNil(session.client)
        XCTAssertTrue(SeerrStubServer.requests.isEmpty, "no request server, no Seerr traffic")
    }

    func testASavedServerAddressSurvivesARelaunch() {
        let first = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)
        XCTAssertTrue(first.setServerAddress("requests.example.com"))

        let relaunched = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)

        XCTAssertEqual(relaunched.serverURL?.absoluteString, "https://requests.example.com")
        XCTAssertTrue(relaunched.canSignIn)
    }

    func testAnAddressSavedByAnEarlierVersionKeepsWorking() {
        defaults.set("https://requests.example.com", forKey: "seerr.serverURL")

        let session = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)

        XCTAssertEqual(session.serverURL?.absoluteString, "https://requests.example.com")
    }

    func testSignInIsOfferedOnlyForAValidAddress() {
        XCTAssertFalse(SeerrSession.canSignIn(serverText: ""))
        XCTAssertFalse(SeerrSession.canSignIn(serverText: "   "))
        XCTAssertFalse(SeerrSession.canSignIn(serverText: "ftp://requests.example.com"))
        XCTAssertFalse(SeerrSession.canSignIn(serverText: "https://"))
        XCTAssertTrue(SeerrSession.canSignIn(serverText: "requests.example.com"))
        XCTAssertTrue(SeerrSession.canSignIn(serverText: "http://192.168.1.20:5055"))
    }

    func testAnEmptyAddressIsNotSaved() {
        let session = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)

        XCTAssertFalse(session.setServerAddress(""))
        XCTAssertNil(session.serverURL)
        XCTAssertNil(defaults.string(forKey: "seerr.serverURL"))
    }

    func testServerAddressesAreNormalised() {
        XCTAssertEqual(SeerrSession.normalizedServerURL("requests.example.com")?.absoluteString, "https://requests.example.com")
        XCTAssertEqual(SeerrSession.normalizedServerURL(" http://192.168.86.151:5055/ ")?.absoluteString, "http://192.168.86.151:5055")
        XCTAssertEqual(SeerrSession.normalizedServerURL("https://example.com/seerr/")?.absoluteString, "https://example.com/seerr")
        XCTAssertNil(SeerrSession.normalizedServerURL(""))
        XCTAssertNil(SeerrSession.normalizedServerURL("ftp://example.com"))
    }

    func testLocalSignInStoresTheCookieUnderTheServerAndSignsIn() async {
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(id: 3, name: "guest"), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        let session = session()

        await session.signInLocal(email: "guest@example.com", password: "pw")

        XCTAssertEqual(session.state, .signedIn(SeerrUser(id: 3, displayName: "guest", email: "mom@example.com")))
        XCTAssertTrue(session.isActive)
        XCTAssertNotNil(session.client)
        XCTAssertEqual(credentials.cookie(forKey: cookieKey), SeerrFixtures.sessionCookie)
    }

    func testAFailedSignInStaysSignedOutWithAMessage() async {
        SeerrStubServer.on("POST", "/api/v1/auth/local", status: 403, body: "{\"message\":\"Access denied.\"}")
        let session = session()

        await session.signInLocal(email: "guest@example.com", password: "nope")

        XCTAssertEqual(session.state, .notConfigured)
        XCTAssertEqual(session.errorMessage, "That email and password didn't work.")
        XCTAssertTrue(credentials.values.isEmpty)
    }

    func testPlexSignInShowsTheCodeThenSignsInOnceLinked() async throws {
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":null}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":\"plex-token\"}")
        SeerrStubServer.on("POST", "/api/v1/auth/plex", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        let session = session()

        let pin = await session.beginPlexSignIn(strong: false)
        XCTAssertEqual(session.state, .awaitingPlex(code: "K7QF"))

        await session.completePlexSignIn(pin: try XCTUnwrap(pin))

        XCTAssertEqual(session.state.user?.id, 7)
        XCTAssertEqual(SeerrStubServer.requests("GET", "/api/v2/pins/42").count, 2)
        XCTAssertEqual(SeerrStubServer.requests("POST", "/api/v1/auth/plex").first?.json?["authToken"] as? String, "plex-token")
        XCTAssertEqual(credentials.cookie(forKey: cookieKey), SeerrFixtures.sessionCookie)
    }

    private func stubPlexSignIn() {
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")
        SeerrStubServer.on("GET", "/api/v2/pins/42", body: "{\"id\":42,\"code\":\"K7QF\",\"authToken\":\"plex-token\"}")
    }

    func testPlexSignInHandsTheTokenToTheObserverAfterSigningIn() async throws {
        stubPlexSignIn()
        SeerrStubServer.on("POST", "/api/v1/auth/plex", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        let session = session()
        var received: [String] = []
        var userIdAtCall: Int?
        session.plexTokenObserver = { token in
            received.append(token)
            userIdAtCall = session.state.user?.id
        }

        let pin = await session.beginPlexSignIn(strong: false)
        await session.completePlexSignIn(pin: try XCTUnwrap(pin))
        await session.lastPlexTokenHandOff?.value

        XCTAssertEqual(received, ["plex-token"])
        XCTAssertEqual(userIdAtCall, 7)
    }

    func testAFailedPlexSignInNeverCallsTheObserver() async throws {
        stubPlexSignIn()
        SeerrStubServer.on("POST", "/api/v1/auth/plex", status: 403, body: "{\"message\":\"Access denied.\"}")
        let session = session()
        var calls = 0
        session.plexTokenObserver = { _ in calls += 1 }

        let pin = await session.beginPlexSignIn(strong: false)
        await session.completePlexSignIn(pin: try XCTUnwrap(pin))

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(session.state, .notConfigured)
    }

    func testSeerrSignInStaysSignedInWhenTheWatchlistLinkFails() async throws {
        stubPlexSignIn()
        SeerrStubServer.on("POST", "/api/v1/auth/plex", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        JellyfinRouteStub.reset()
        JellyfinRouteStub.routes = [
            "GET /SashimiLists/Watchlist": (500, ""),
            "POST /SashimiLists/Watchlist/Plex": (500, "")
        ]
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        defer { JellyfinClient.testURLProtocolClasses = [] }
        let jellyfin = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        let store = WatchlistStore(service: WatchlistService(client: jellyfin))
        let session = session()
        var finished = false
        session.plexTokenObserver = { token in
            await store.autoLink(token: token)
            finished = true
        }

        let pin = await session.beginPlexSignIn(strong: false)
        await session.completePlexSignIn(pin: try XCTUnwrap(pin))
        await session.lastPlexTokenHandOff?.value

        XCTAssertTrue(finished)
        XCTAssertEqual(session.state.user?.id, 7)
        XCTAssertNil(session.errorMessage)
    }

    func testCancellingPlexSignInGoesBackToSignedOut() async throws {
        SeerrStubServer.on("POST", "/api/v2/pins", status: 201, body: "{\"id\":42,\"code\":\"K7QF\"}")
        let session = session()

        _ = await session.beginPlexSignIn(strong: false)
        session.cancelPlexSignIn()

        XCTAssertEqual(session.state, .notConfigured)
    }

    func testRestoreWithAStoredCookieChecksItWithTheServer() async {
        credentials.setCookie(SeerrFixtures.sessionCookie, forKey: cookieKey)
        SeerrStubServer.on("GET", "/api/v1/auth/me", body: SeerrFixtures.user())
        SeerrStubServer.on("GET", "/api/v1/settings/public", body: "{\"applicationTitle\":\"MondoVision\",\"partialRequestsEnabled\":false}")
        let session = session()

        await session.restore()

        XCTAssertEqual(session.state.user?.name, "mom")
        XCTAssertEqual(session.applicationTitle, "MondoVision")
        XCTAssertFalse(session.partialRequestsEnabled)
    }

    func testRestoreWithoutAnAccountNeverContactsTheServer() async {
        let session = session()

        await session.restore()

        XCTAssertEqual(session.state, .notConfigured)
        XCTAssertTrue(SeerrStubServer.requests.isEmpty, "installs that never set up requests stay off the network")
    }

    func testRestoreWithAnExpiredCookieAsksToSignInAgain() async {
        credentials.setCookie(SeerrFixtures.sessionCookie, forKey: cookieKey)
        SeerrStubServer.on("GET", "/api/v1/auth/me", status: 401, body: "{}")
        let session = session()

        await session.restore()

        XCTAssertEqual(session.state, .expired)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(credentials.cookie(forKey: cookieKey), "a dead cookie is dropped")
    }

    func testRestoreOfflineKeepsTheLastKnownAccount() async {
        credentials.setCookie(SeerrFixtures.sessionCookie, forKey: cookieKey)
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        let first = session()
        await first.signInLocal(email: "mom@example.com", password: "pw")
        SeerrStubServer.reset()
        SeerrStubServer.on("GET", "/api/v1/auth/me", status: 502, body: "Bad gateway")

        let relaunched = session()
        await relaunched.restore()

        XCTAssertEqual(relaunched.state.user?.id, 7, "a server hiccup is not a sign-out")
    }

    func testAnUnauthorizedAnswerLaterChecksAndFallsBackToExpired() async {
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        SeerrStubServer.on("GET", "/api/v1/auth/me", status: 403, body: "{}")
        let session = session()
        await session.signInLocal(email: "mom@example.com", password: "pw")

        await session.handle(SeerrError.unauthorized)

        XCTAssertEqual(session.state, .expired)
    }

    func testAnUnauthorizedAnswerWithAStillGoodSessionStaysSignedIn() async {
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        SeerrStubServer.on("GET", "/api/v1/auth/me", body: SeerrFixtures.user())
        let session = session()
        await session.signInLocal(email: "mom@example.com", password: "pw")

        await session.handle(SeerrError.unauthorized)

        XCTAssertTrue(session.isActive, "e.g. a 401 for cancelling a request that is no longer pending")
    }

    func testSignOutTellsTheServerAndForgetsTheCookie() async {
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        SeerrStubServer.on("POST", "/api/v1/auth/logout", body: "{\"status\":\"ok\"}")
        let session = session()
        await session.signInLocal(email: "mom@example.com", password: "pw")

        await session.signOut()

        XCTAssertEqual(session.state, .notConfigured)
        XCTAssertNil(session.client)
        XCTAssertNil(credentials.cookie(forKey: cookieKey))
        XCTAssertEqual(SeerrStubServer.requests("POST", "/api/v1/auth/logout").first?.headers["Cookie"], SeerrFixtures.sessionCookie)
    }

    func testTheServerCanOnlyChangeWhileSignedOut() async {
        SeerrStubServer.on("POST", "/api/v1/auth/local", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
        let session = session()
        await session.signInLocal(email: "mom@example.com", password: "pw")

        XCTAssertFalse(session.setServerAddress("other.example.com"))
        XCTAssertEqual(session.serverURL, SeerrFixtures.server)
    }

    func testCookiesAreScopedPerServer() throws {
        XCTAssertNotEqual(
            SeerrSession.cookieKey(for: try XCTUnwrap(URL(string: "https://requests.example.com"))),
            SeerrSession.cookieKey(for: try XCTUnwrap(URL(string: "http://192.168.86.151:5055")))
        )
    }
}

/// The Watchlist auto-link runs in the background: it never holds up or fails sign-in.
extension SeerrSessionTests {
    // MARK: The Watchlist link never holds up sign-in

    private func signInStubs() {
        stubPlexSignIn()
        SeerrStubServer.on("POST", "/api/v1/auth/plex", body: SeerrFixtures.user(), headers: ["Set-Cookie": SeerrFixtures.setCookie])
    }

    private func watchlistStore(routes: [String: (Int, String)]) throws -> WatchlistStore {
        JellyfinRouteStub.reset()
        JellyfinRouteStub.routes = routes
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        addTeardownBlock { JellyfinClient.testURLProtocolClasses = [] }
        let jellyfin = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        return WatchlistStore(service: WatchlistService(client: jellyfin))
    }

    func testRequestsSignInDoesNotWaitForWatchlistLink() async throws {
        signInStubs()
        let session = session()
        let (gate, release) = AsyncStream<Void>.makeStream()
        var observerStarted = false
        session.plexTokenObserver = { _ in
            observerStarted = true
            for await _ in gate { break }
        }
        let begun = await session.beginPlexSignIn(strong: false)
        let pin = try XCTUnwrap(begun)
        var returned = false
        let signIn = Task { @MainActor in
            await session.completePlexSignIn(pin: pin)
            returned = true
        }
        for _ in 0..<100 where !returned { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertTrue(returned, "sign-in waited for the Watchlist link")
        XCTAssertEqual(session.state.user?.id, 7)
        XCTAssertNil(session.errorMessage)

        release.yield()
        release.finish()
        await signIn.value
        await session.lastPlexTokenHandOff?.value
        XCTAssertTrue(observerStarted)
    }

    func testRequestsSignInSucceedsWhenWatchlistIsMissing() async throws {
        signInStubs()
        let store = try watchlistStore(routes: [:])
        let session = session()
        session.plexTokenObserver = { token in await store.autoLink(token: token) }

        let pin = await session.beginPlexSignIn(strong: false)
        await session.completePlexSignIn(pin: try XCTUnwrap(pin))
        await session.lastPlexTokenHandOff?.value

        XCTAssertEqual(session.state.user?.id, 7)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/SashimiLists/Watchlist").count, 1)
        XCTAssertTrue(JellyfinRouteStub.requests("POST", "/SashimiLists/Watchlist/Plex").isEmpty)
    }

    func testRequestsSignInIsPromptWhenTheWatchlistServerIsSlow() async throws {
        signInStubs()
        let store = try watchlistStore(routes: ["GET /SashimiLists/Watchlist": (404, "")])
        JellyfinRouteStub.delays["GET /SashimiLists/Watchlist"] = 3
        let session = session()
        session.plexTokenObserver = { token in await store.autoLink(token: token) }

        let pin = await session.beginPlexSignIn(strong: false)
        let start = ContinuousClock.now
        await session.completePlexSignIn(pin: try XCTUnwrap(pin))
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(session.state.user?.id, 7)
        XCTAssertNil(session.errorMessage)
        await session.lastPlexTokenHandOff?.value
    }

    func testRequestsSignInSucceedsWhenPlexRejectsTheWatchlistToken() async throws {
        signInStubs()
        let store = try watchlistStore(routes: [
            "GET /SashimiLists/Watchlist": (200, "{\"items\":[]}"),
            "POST /SashimiLists/Watchlist/Plex": (422, "")
        ])
        let session = session()
        session.plexTokenObserver = { token in await store.autoLink(token: token) }

        let pin = await session.beginPlexSignIn(strong: false)
        await session.completePlexSignIn(pin: try XCTUnwrap(pin))
        await session.lastPlexTokenHandOff?.value

        XCTAssertEqual(session.state.user?.id, 7)
        XCTAssertNil(session.errorMessage)
    }
}
