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

    func testANewInstallIsNotSetUpAndPointsAtTheDefaultServer() {
        let session = SeerrSession(defaults: defaults, credentials: credentials, pollInterval: .zero)

        XCTAssertEqual(session.state, .notConfigured)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.client)
        XCTAssertEqual(session.serverURL.absoluteString, "https://bitstorm.ca")
    }

    func testServerAddressesAreNormalised() {
        XCTAssertEqual(SeerrSession.normalizedServerURL("bitstorm.ca")?.absoluteString, "https://bitstorm.ca")
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

    func testCookiesAreScopedPerServer() {
        XCTAssertNotEqual(
            SeerrSession.cookieKey(for: URL(string: "https://bitstorm.ca")!),
            SeerrSession.cookieKey(for: URL(string: "http://192.168.86.151:5055")!)
        )
    }
}
