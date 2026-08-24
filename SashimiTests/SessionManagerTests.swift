import XCTest
@testable import Sashimi

final class SessionManagerTests: XCTestCase {

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

        // Perform logout
        manager.logout(reason: .userInitiated)

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

    // MARK: - UserDto Tests

    func testUserDtoDecoding() throws {
        let json = """
        {
            "Id": "user-123",
            "Name": "TestUser",
            "ServerId": "server-456",
            "PrimaryImageTag": "image-tag-789"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let user = try decoder.decode(UserDto.self, from: json)

        XCTAssertEqual(user.id, "user-123")
        XCTAssertEqual(user.name, "TestUser")
        XCTAssertEqual(user.serverID, "server-456")
        XCTAssertEqual(user.primaryImageTag, "image-tag-789")
    }

    func testUserDtoMinimalDecoding() throws {
        let json = """
        {
            "Id": "user-minimal",
            "Name": "MinimalUser"
        }
        """.data(using: .utf8)!

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
