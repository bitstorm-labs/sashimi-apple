import XCTest
@testable import Sashimi

final class ServerEditTests: XCTestCase {
    func testDisplayNameUsesAliasAndFallsBackToJellyfinName() {
        let server = makeServer(name: "Finney", nameOverride: "Home")
        XCTAssertEqual(server.displayName, "Home")

        let cleared = makeServer(name: "Finney", nameOverride: "   ")
        XCTAssertEqual(cleared.displayName, "Finney")
    }

    func testLegacyServerConfigDecodesWithoutAnAlias() throws {
        let data = """
        {
            "id": "server-1",
            "name": "Finney",
            "url": "https://fin.example",
            "username": "tester",
            "userId": "user-1"
        }
        """.data(using: .utf8)!

        let server = try JSONDecoder().decode(ServerConfig.self, from: data)
        XCTAssertNil(server.nameOverride)
        XCTAssertEqual(server.displayName, "Finney")
    }

    func testAliasOnlyEditSkipsAuthentication() async throws {
        let calls = AuthenticationCallCounter()
        let current = makeServer(name: "Finney")
        let request = ServerEditRequest(
            nameOverride: "Living Room",
            serverURL: current.url,
            username: current.username,
            password: nil
        )

        let prepared = try await ServerEditCoordinator.prepare(current: current, request: request) { _, _, _ in
            await calls.increment()
            return ServerEditAuthentication(
                accessToken: "unused",
                username: current.username,
                userId: current.userId,
                serverName: current.name
            )
        }

        let authenticationCalls = await calls.value
        XCTAssertEqual(authenticationCalls, 0)
        XCTAssertEqual(prepared.server.displayName, "Living Room")
        XCTAssertEqual(prepared.server.userId, current.userId)
        XCTAssertNil(prepared.accessToken)
        XCTAssertFalse(request.changesConnection(from: current))
    }

    func testAliasOnlyEditTreatsTrailingSlashAsTheSameConnection() async throws {
        let current = makeServer(
            name: "Finney",
            url: URL(string: "https://fin.example/")!
        )
        let request = ServerEditRequest(
            nameOverride: "Living Room",
            serverURL: current.url,
            username: current.username,
            password: nil
        )

        let prepared = try await ServerEditCoordinator.prepare(current: current, request: request) { _, _, _ in
            XCTFail("Authentication should not start for an alias-only edit")
            return ServerEditAuthentication(
                accessToken: "unused",
                username: current.username,
                userId: current.userId,
                serverName: current.name
            )
        }

        XCTAssertFalse(request.urlChanged(from: current))
        XCTAssertFalse(request.changesConnection(from: current))
        XCTAssertEqual(prepared.server.url, current.url)
        XCTAssertEqual(prepared.server.displayName, "Living Room")
        XCTAssertNil(prepared.accessToken)
    }

    func testCredentialEditKeepsIdentityAndUsesFreshAuthentication() async throws {
        let current = makeServer(name: "Finney")
        let newURL = URL(string: "https://new-fin.example")!
        let request = ServerEditRequest(
            nameOverride: "Updated Finney",
            serverURL: newURL,
            username: "new-user",
            password: "new-password"
        )

        let prepared = try await ServerEditCoordinator.prepare(current: current, request: request) { url, username, password in
            XCTAssertEqual(url, newURL)
            XCTAssertEqual(username, "new-user")
            XCTAssertEqual(password, "new-password")
            return ServerEditAuthentication(
                accessToken: "fresh-token",
                username: "new-user",
                userId: "new-user-id",
                serverName: "New Finney"
            )
        }

        XCTAssertEqual(prepared.server.id, current.id)
        XCTAssertEqual(prepared.server.url, newURL)
        XCTAssertEqual(prepared.server.username, "new-user")
        XCTAssertEqual(prepared.server.userId, "new-user-id")
        XCTAssertEqual(prepared.server.name, "New Finney")
        XCTAssertEqual(prepared.server.displayName, "Updated Finney")
        XCTAssertEqual(prepared.accessToken, "fresh-token")
        XCTAssertTrue(request.changesConnection(from: current))
    }

    @MainActor
    func testSessionUpdatePersistsAliasWithoutRefreshingActiveSession() async throws {
        let harness = SessionManagerTestHarness()
        defer { harness.restore() }
        harness.installToken("old-token")
        let current = harness.server

        let initialIdentity = harness.manager.activeSessionIdentity
        try await harness.manager.updateServer(
            id: harness.server.id,
            nameOverride: "Living Room",
            serverURL: harness.server.url,
            username: harness.server.username,
            password: nil,
            authenticate: { _, _, _ in
                XCTFail("Alias-only edits should not authenticate")
                return ServerEditAuthentication(
                    accessToken: "unused",
                    username: current.username,
                    userId: current.userId,
                    serverName: current.name
                )
            }
        )

        XCTAssertEqual(harness.manager.activeSessionIdentity, initialIdentity)
        XCTAssertEqual(harness.manager.servers.first?.displayName, "Living Room")
        XCTAssertEqual(harness.persistedServer()?.displayName, "Living Room")
        await harness.clearClient()
    }

    @MainActor
    func testSessionUpdatePersistsCredentialsAndRefreshesActiveSession() async throws {
        let harness = SessionManagerTestHarness()
        defer { harness.restore() }
        harness.installToken("old-token")

        let newURL = URL(string: "https://new-fin.example")!
        let initialIdentity = harness.manager.activeSessionIdentity
        try await harness.manager.updateServer(
            id: harness.server.id,
            nameOverride: "Updated Finney",
            serverURL: newURL,
            username: "new-user",
            password: "new-password",
            authenticate: { url, username, password in
                XCTAssertEqual(url, newURL)
                XCTAssertEqual(username, "new-user")
                XCTAssertEqual(password, "new-password")
                return ServerEditAuthentication(
                    accessToken: "fresh-token",
                    username: "new-user",
                    userId: "new-user-id",
                    serverName: "New Finney"
                )
            }
        )

        XCTAssertNotEqual(harness.manager.activeSessionIdentity, initialIdentity)
        XCTAssertEqual(harness.manager.serverConnectionRevision, 1)
        XCTAssertEqual(harness.manager.serverURL, newURL)
        XCTAssertEqual(harness.manager.servers.first?.url, newURL)
        XCTAssertEqual(harness.manager.servers.first?.userId, "new-user-id")
        XCTAssertEqual(KeychainHelper.get(forKey: harness.manager.tokenKey(harness.server.id)), "fresh-token")
        XCTAssertEqual(harness.persistedServer()?.url, newURL)
        await harness.clearClient()
    }

    @MainActor
    func testSessionUpdateFailureLeavesSessionAndPersistenceUnchanged() async throws {
        let harness = SessionManagerTestHarness()
        defer { harness.restore() }
        harness.installToken("old-token")

        let initialIdentity = harness.manager.activeSessionIdentity
        do {
            try await harness.manager.updateServer(
                id: harness.server.id,
                nameOverride: "Should Not Save",
                serverURL: URL(string: "https://new-fin.example")!,
                username: "new-user",
                password: "bad-password",
                authenticate: { _, _, _ in
                    throw TestAuthenticationError.denied
                }
            )
            XCTFail("The failed authentication should be returned")
        } catch TestAuthenticationError.denied {
            // Expected.
        }

        XCTAssertEqual(harness.manager.activeSessionIdentity, initialIdentity)
        XCTAssertEqual(harness.manager.servers, [harness.server])
        XCTAssertEqual(harness.persistedServer(), harness.server)
        XCTAssertEqual(KeychainHelper.get(forKey: harness.manager.tokenKey(harness.server.id)), "old-token")
        await harness.clearClient()
    }

    func testConnectionChangeRequiresPassword() async {
        let current = makeServer(name: "Finney")
        let request = ServerEditRequest(
            nameOverride: nil,
            serverURL: URL(string: "https://new-fin.example")!,
            username: current.username,
            password: nil
        )

        do {
            _ = try await ServerEditCoordinator.prepare(current: current, request: request) { _, _, _ in
                XCTFail("Authentication should not start without a password")
                return ServerEditAuthentication(
                    accessToken: "unused",
                    username: current.username,
                    userId: current.userId,
                    serverName: current.name
                )
            }
            XCTFail("The edit should require a password")
        } catch let error as SessionError {
            XCTAssertEqual(error.localizedDescription, SessionError.passwordRequiredForConnectionChange.localizedDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthenticationFailureDoesNotMutateTheOriginalRecord() async {
        let current = makeServer(name: "Finney")
        let original = current
        let request = ServerEditRequest(
            nameOverride: "Should Not Save",
            serverURL: current.url,
            username: current.username,
            password: "bad-password"
        )

        do {
            _ = try await ServerEditCoordinator.prepare(current: current, request: request) { _, _, _ in
                throw TestAuthenticationError.denied
            }
            XCTFail("The authentication error should be returned")
        } catch TestAuthenticationError.denied {
            XCTAssertEqual(current, original)
            XCTAssertEqual(current.displayName, "Finney")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeServer(
        name: String,
        nameOverride: String? = nil,
        url: URL = URL(string: "https://fin.example")!
    ) -> ServerConfig {
        ServerConfig(
            id: "server-1",
            name: name,
            url: url,
            username: "tester",
            userId: "user-1",
            nameOverride: nameOverride
        )
    }
}

private actor AuthenticationCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private enum TestAuthenticationError: Error {
    case denied
}

@MainActor
private final class SessionManagerTestHarness {
    private static let defaultKeys = [
        "servers",
        "activeServerId",
        "serverURL",
        "userId",
        "userName",
        "legacyAccessTokenServerID"
    ]

    let manager: SessionManager
    let server: ServerConfig
    private let defaultValues: [String: Any]
    private let keychainValues: [String: String]

    init() {
        let defaults = UserDefaults.standard
        var defaultValues: [String: Any] = [:]
        for key in Self.defaultKeys {
            if let value = defaults.object(forKey: key) {
                defaultValues[key] = value
            }
        }

        let manager = SessionManager(restoreOnLaunch: false)
        let server = ServerConfig(
            id: "server-edit-harness-\(UUID().uuidString)",
            name: "Finney",
            url: URL(string: "https://fin.example")!,
            username: "tester",
            userId: "user-1"
        )
        let keychainKeys = [manager.tokenKey(server.id), "accessToken"]
        var keychainValues: [String: String] = [:]
        for key in keychainKeys {
            if let value = KeychainHelper.get(forKey: key) {
                keychainValues[key] = value
            }
        }

        self.manager = manager
        self.server = server
        self.defaultValues = defaultValues
        self.keychainValues = keychainValues

        manager.servers = [server]
        manager.activeServerId = server.id
        _ = manager.saveServers()
    }

    func installToken(_ token: String) {
        _ = KeychainHelper.save(token, forKey: manager.tokenKey(server.id))
    }

    func persistedServer() -> ServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: "servers") else { return nil }
        return try? JSONDecoder().decode([ServerConfig].self, from: data).first
    }

    func clearClient() async {
        await JellyfinClient.shared.clearCredentials()
    }

    func restore() {
        let defaults = UserDefaults.standard
        for key in Self.defaultKeys {
            if let value = defaultValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let tokenKeys = [manager.tokenKey(server.id), "accessToken"]
        for key in tokenKeys {
            if let value = keychainValues[key] {
                _ = KeychainHelper.save(value, forKey: key)
            } else {
                _ = KeychainHelper.delete(forKey: key)
            }
        }
    }
}
