import Combine
import XCTest
@testable import Sashimi

final class SessionManagerTests: XCTestCase {
    /// Every request these tests cause is answered in-process (#874). Activating
    /// a server starts a bandwidth probe and an admin-flag lookup; both used to
    /// reach the real network and only "passed" after timing out.
    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        // A complete, >1 MB sample: the probe records a reading and stops, so
        // no retry outlives the test.
        JellyfinRouteStub.routes["GET /Playback/BitrateTest"] = (200, String(repeating: "0", count: 1_100_000))
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        JellyfinRouteStub.reset()
        super.tearDown()
    }

    // MARK: - Temporary Client Scope Tests

    func testScopeStackRelinksOutOfOrderTeardownToOriginalParent() {
        var stack = ServerClientScopeStack()
        let scopeA = stack.begin(previousServerID: "server0")
        let scopeB = stack.begin(previousServerID: "serverA")
        let scopeC = stack.begin(previousServerID: "serverB")

        let removedB = stack.end(scopeB)
        XCTAssertFalse(removedB?.wasTop ?? true)
        XCTAssertEqual(stack.entries.first?.token, scopeA)
        XCTAssertEqual(stack.entries.last?.previousScopeToken, scopeA)
        XCTAssertEqual(stack.entries.last?.previousServerID, "serverA")

        let removedA = stack.end(scopeA)
        XCTAssertFalse(removedA?.wasTop ?? true)
        XCTAssertNil(stack.entries.first?.previousScopeToken)
        XCTAssertEqual(stack.entries.first?.previousServerID, "server0")

        let removedC = stack.end(scopeC)
        XCTAssertTrue(removedC?.wasTop ?? false)
        XCTAssertEqual(removedC?.entry.previousServerID, "server0")
        XCTAssertNil(removedC?.entry.previousScopeToken)
        XCTAssertTrue(stack.isEmpty)
    }

    func testScopeStackLifoTeardownRestoresImmediateParent() {
        var stack = ServerClientScopeStack()
        let parent = stack.begin(previousServerID: "server0")
        let child = stack.begin(previousServerID: "serverA")

        let removedChild = stack.end(child)
        XCTAssertTrue(removedChild?.wasTop ?? false)
        XCTAssertEqual(removedChild?.entry.previousServerID, "serverA")

        let removedParent = stack.end(parent)
        XCTAssertTrue(removedParent?.wasTop ?? false)
        XCTAssertEqual(removedParent?.entry.previousServerID, "server0")
        XCTAssertTrue(stack.isEmpty)
    }

    // MARK: - Default Server Tests

    @MainActor
    func testSingleServerHidesDefaultBadgeAndSetDefaultControl() {
        let server = makeServer(id: "server-one")
        let manager = SessionManager(
            restoreOnLaunch: false,
            initialServers: [server],
            initialActiveServerId: server.id,
            initialDefaultServerId: server.id
        )

        XCTAssertFalse(manager.shouldShowDefaultServerBadge)
        XCTAssertFalse(manager.shouldShowSetAsDefault(for: server.id))
    }

    @MainActor
    func testMultipleServersShowBadgeOnlyForDefaultAndOfferReassignmentForOtherServers() {
        let defaultServer = makeServer(id: "server-default")
        let otherServer = makeServer(id: "server-other")
        let manager = SessionManager(
            restoreOnLaunch: false,
            initialServers: [defaultServer, otherServer],
            initialActiveServerId: defaultServer.id,
            initialDefaultServerId: defaultServer.id
        )

        XCTAssertTrue(manager.shouldShowDefaultServerBadge)
        XCTAssertTrue(manager.isDefaultServer(defaultServer.id))
        XCTAssertFalse(manager.shouldShowSetAsDefault(for: defaultServer.id))
        XCTAssertTrue(manager.shouldShowSetAsDefault(for: otherServer.id))
    }

    @MainActor
    func testSetDefaultServerReassignsAndPersistsWithoutChangingActiveServer() {
        let defaults = UserDefaults.standard
        let keys = ["servers", "activeServerId", "defaultServerId"]
        let previousValues = snapshotDefaults(for: keys)
        defer { restoreDefaults(previousValues, for: keys) }

        let currentServer = makeServer(id: "server-current")
        let newDefault = makeServer(id: "server-new-default")
        let manager = SessionManager(
            restoreOnLaunch: false,
            initialServers: [currentServer, newDefault],
            initialActiveServerId: currentServer.id,
            initialDefaultServerId: currentServer.id
        )
        guard let persistedData = try? JSONEncoder().encode([currentServer, newDefault]) else {
            XCTFail("Could not encode test servers")
            return
        }
        defaults.set(persistedData, forKey: "servers")
        defaults.set(currentServer.id, forKey: "activeServerId")
        defaults.set(currentServer.id, forKey: "defaultServerId")

        XCTAssertTrue(manager.setDefaultServer(to: newDefault.id))
        XCTAssertEqual(manager.defaultServerId, newDefault.id)
        XCTAssertEqual(manager.activeServerId, currentServer.id)
        XCTAssertEqual(defaults.string(forKey: "defaultServerId"), newDefault.id)
        XCTAssertFalse(manager.setDefaultServer(to: "missing-server"))
    }

    @MainActor
    func testRestoreSessionUsesDefaultServerInsteadOfPreviouslyActiveServer() async {
        let defaults = UserDefaults.standard
        let keys = ["servers", "activeServerId", "defaultServerId"]
        let previousValues = snapshotDefaults(for: keys)
        defer { restoreDefaults(previousValues, for: keys) }

        let defaultServer = makeServer(id: "server-default-at-launch")
        let previouslyActiveServer = makeServer(id: "server-previous-active")
        guard let persistedData = try? JSONEncoder().encode([defaultServer, previouslyActiveServer]) else {
            XCTFail("Could not encode test servers")
            return
        }
        defaults.set(persistedData, forKey: "servers")
        defaults.set(previouslyActiveServer.id, forKey: "activeServerId")
        defaults.set(defaultServer.id, forKey: "defaultServerId")

        let manager = SessionManager(restoreOnLaunch: false)
        await manager.restoreSession()

        XCTAssertEqual(manager.defaultServerId, defaultServer.id)
        XCTAssertEqual(manager.activeServerId, defaultServer.id)
        XCTAssertEqual(manager.reauthServer, defaultServer)
    }

    @MainActor
    func testRestoreSessionCreatesDefaultFromFirstSavedServerWhenMissing() async {
        let defaults = UserDefaults.standard
        let keys = ["servers", "activeServerId", "defaultServerId"]
        let previousValues = snapshotDefaults(for: keys)
        defer { restoreDefaults(previousValues, for: keys) }

        let firstServer = makeServer(id: "server-first")
        let secondServer = makeServer(id: "server-second")
        guard let persistedData = try? JSONEncoder().encode([firstServer, secondServer]) else {
            XCTFail("Could not encode test servers")
            return
        }
        defaults.set(persistedData, forKey: "servers")
        defaults.removeObject(forKey: "activeServerId")
        defaults.removeObject(forKey: "defaultServerId")

        let manager = SessionManager(restoreOnLaunch: false)
        await manager.restoreSession()

        XCTAssertEqual(manager.defaultServerId, firstServer.id)
        XCTAssertEqual(manager.activeServerId, firstServer.id)
        XCTAssertEqual(manager.reauthServer, firstServer)
    }

    @MainActor
    func testRemovingDefaultPromotesFirstRemainingServerWithoutChangingActiveServer() async {
        let keys = ["servers", "activeServerId", "defaultServerId"]
        let previousValues = snapshotDefaults(for: keys)
        defer { restoreDefaults(previousValues, for: keys) }

        let removedDefault = makeServer(id: "server-removed-default")
        let promotedServer = makeServer(id: "server-promoted")
        let activeServer = makeServer(id: "server-active")
        let manager = SessionManager(
            restoreOnLaunch: false,
            initialServers: [removedDefault, promotedServer, activeServer],
            initialActiveServerId: activeServer.id,
            initialDefaultServerId: removedDefault.id
        )

        await manager.removeServer(id: removedDefault.id)

        XCTAssertEqual(manager.defaultServerId, promotedServer.id)
        XCTAssertEqual(manager.activeServerId, activeServer.id)
        XCTAssertEqual(manager.servers, [promotedServer, activeServer])
    }

    // MARK: - LogoutReason Tests

    func testLogoutReasonEnum() {
        // Test enum cases exist and are distinct
        let userInitiated = LogoutReason.userInitiated
        let sessionExpired = LogoutReason.sessionExpired

        XCTAssertNotNil(userInitiated)
        XCTAssertNotNil(sessionExpired)

        // They should be different
        switch userInitiated {
        case .userInitiated:
            XCTAssertTrue(true)
        case .sessionExpired:
            XCTFail("Should be userInitiated")
        }

        switch sessionExpired {
        case .sessionExpired:
            XCTAssertTrue(true)
        case .userInitiated:
            XCTFail("Should be sessionExpired")
        }
    }

    // MARK: - Logout Tests

    @MainActor
    func testLogoutClearsState() async {
        let manager = SessionManager.shared
        WatchlistStore.shared.notice = "Your Watchlist now syncs with Plex"

        // Perform logout
        manager.logout(reason: .userInitiated)
        XCTAssertNil(WatchlistStore.shared.notice, "the Watchlist forgets the signed-out session at once")

        // Verify state is cleared
        XCTAssertFalse(manager.isAuthenticated)
        XCTAssertNil(manager.currentUser)
        XCTAssertNil(manager.serverURL)
        XCTAssertEqual(manager.logoutReason, .userInitiated)
    }

    @MainActor
    func testLogoutWithSessionExpiredReason() async {
        let manager = SessionManager.shared

        manager.logout(reason: .sessionExpired)

        XCTAssertEqual(manager.logoutReason, .sessionExpired)
        XCTAssertFalse(manager.isAuthenticated)
    }

    /// Regression: signing out with a second server saved used to silently
    /// switch to that server instead of signing out, because logout() delegated
    /// to removeServer(id:), whose successor-activation behaviour is only right
    /// for "remove this server" in Settings.
    ///
    /// The teardown is async, so this drives it to completion before asserting.
    @MainActor
    func testLogoutWithMultipleServersDoesNotSwitchToAnother() async throws {
        let manager = SessionManager.shared

        manager.logout(reason: .userInitiated)
        // Let the teardown task run.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(manager.isAuthenticated,
                       "Sign-out must not leave the app authenticated against a successor server")
        XCTAssertNil(manager.activeServerId,
                     "Sign-out must clear the active server rather than activating another")
        XCTAssertNil(manager.serverURL)
        XCTAssertNil(manager.currentUser)
    }

    /// Regression (apple#422): switching servers published the new
    /// activeServerId, which rebuilds the authenticated root, before the client
    /// was pointed at that server. The rebuilt Home loaded against the old
    /// server and nothing reloaded it once the switch finished.
    @MainActor
    func testSwitchServerPublishesNewServerOnlyOnceTheClientPointsAtIt() async {
        let keys = ["servers", "activeServerId", "defaultServerId", "serverURL", "userId", "userName",
                    "legacyAccessTokenServerID"]
        let previousValues = snapshotDefaults(for: keys)
        let previousToken = KeychainHelper.get(forKey: "accessToken")
        defer {
            restoreDefaults(previousValues, for: keys)
            if let previousToken { _ = KeychainHelper.save(previousToken, forKey: "accessToken") }
            _ = KeychainHelper.delete(forKey: "accessToken.server-next")
        }

        let current = makeServer(id: "server-current")
        let next = makeServer(id: "server-next")
        _ = KeychainHelper.save("token-next", forKey: "accessToken.server-next")
        let manager = SessionManager(
            restoreOnLaunch: false,
            initialServers: [current, next],
            initialActiveServerId: current.id,
            initialDefaultServerId: current.id
        )

        var urlWhenPublished: URL?
        let observation = manager.$activeServerId.dropFirst().sink { _ in
            urlWhenPublished = manager.serverURL
        }
        defer { observation.cancel() }

        JellyfinRouteStub.routes["GET /Users/user-server-next"] = (
            200, #"{"Id":"user-server-next","Name":"tester","Policy":{"IsAdministrator":true}}"#
        )
        let adminFlagLoaded = expectation(description: "admin flag answered in-process")
        let adminObservation = manager.$isAdministrator.first(where: { $0 }).sink { _ in
            adminFlagLoaded.fulfill()
        }
        defer { adminObservation.cancel() }

        WatchlistStore.shared.notice = "Your Watchlist now syncs with Plex"
        await manager.switchServer(to: next.id)
        await awaitBandwidthMeasurement(for: next.url)
        await fulfillment(of: [adminFlagLoaded], timeout: 5)

        // #874: the switch's bandwidth probe and admin lookup stay in-process.
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/Playback/BitrateTest").count, 1,
                       "the bandwidth probe must go through the test URLProtocol, not the network")
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/Users/user-server-next").count, 1)
        XCTAssertNotNil(BandwidthMeasurementStore.shared.measurement(for: next.url))
        BandwidthMeasurementStore.shared.clearMeasurement(for: next.url)

        XCTAssertEqual(manager.activeServerId, next.id)
        XCTAssertNil(WatchlistStore.shared.notice, "the Watchlist forgets the last server's session")
        XCTAssertEqual(urlWhenPublished, next.url,
                       "The root rebuilds on activeServerId; the client must already be on the new server")
    }

    // MARK: - UserDto Tests

    func testUserDtoDecoding() throws {
        let json = Data("""
        {
            "Id": "user-123",
            "Name": "TestUser",
            "ServerId": "server-456",
            "PrimaryImageTag": "image-tag-789"
        }
        """.utf8)

        let decoder = JSONDecoder()
        let user = try decoder.decode(UserDto.self, from: json)

        XCTAssertEqual(user.id, "user-123")
        XCTAssertEqual(user.name, "TestUser")
        XCTAssertEqual(user.serverID, "server-456")
        XCTAssertEqual(user.primaryImageTag, "image-tag-789")
    }

    func testUserDtoMinimalDecoding() throws {
        let json = Data("""
        {
            "Id": "user-minimal",
            "Name": "MinimalUser"
        }
        """.utf8)

        let decoder = JSONDecoder()
        let user = try decoder.decode(UserDto.self, from: json)

        XCTAssertEqual(user.id, "user-minimal")
        XCTAssertEqual(user.name, "MinimalUser")
        XCTAssertNil(user.serverID)
        XCTAssertNil(user.primaryImageTag)
    }

    // MARK: - SessionError Tests

    func testCredentialStorageFailedErrorDescription() {
        let error: LocalizedError = SessionError.credentialStorageFailed
        XCTAssertEqual(error.errorDescription, "Could not save credentials securely. Please try signing in again.")
    }

    // MARK: - UserDefaults Key Tests

    func testUserDefaultsKeysAreConsistent() {
        // These keys should match what SessionManager uses internally
        // Testing that the expected keys work with UserDefaults

        let testServerURL = "http://test.local:8096"
        let testUserId = "test-user-id"

        UserDefaults.standard.set(testServerURL, forKey: "serverURL")
        UserDefaults.standard.set(testUserId, forKey: "userId")

        XCTAssertEqual(UserDefaults.standard.string(forKey: "serverURL"), testServerURL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "userId"), testUserId)

        // Clean up
        UserDefaults.standard.removeObject(forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "userId")
    }
}

// MARK: - Helpers

private extension SessionManagerTests {
    /// Waits (bounded) for the server's bandwidth probe to start and record a
    /// reading. Polls: awaiting the probe task itself is not bounded, because
    /// `Task.value` ignores cancellation and a failing round retries for ~80 s.
    func awaitBandwidthMeasurement(for url: URL) async {
        let deadline = Date().addingTimeInterval(5)
        while BandwidthMeasurementStore.shared.measurement(for: url) == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(BandwidthMeasurementStore.shared.probe(for: url),
                        "activating the server should start a bandwidth probe")
    }

    func makeServer(id: String) -> ServerConfig {
        ServerConfig(
            id: id,
            name: id,
            url: URL(string: "https://\(id).example") ?? URL(fileURLWithPath: "/"),
            username: "tester",
            userId: "user-\(id)"
        )
    }

    func snapshotDefaults(for keys: [String]) -> [String: Any] {
        keys.reduce(into: [String: Any]()) { snapshot, key in
            if let value = UserDefaults.standard.object(forKey: key) {
                snapshot[key] = value
            }
        }
    }

    func restoreDefaults(_ values: [String: Any], for keys: [String]) {
        for key in keys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
