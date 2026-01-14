import XCTest
@testable import Sashimi

final class SessionManagerTests: XCTestCase {

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

    @MainActor
    func testClearLogoutReason() async {
        let manager = SessionManager.shared

        // Set a logout reason
        manager.logout(reason: .userInitiated)
        XCTAssertNotNil(manager.logoutReason)

        // Clear it
        manager.clearLogoutReason()
        XCTAssertNil(manager.logoutReason)
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
