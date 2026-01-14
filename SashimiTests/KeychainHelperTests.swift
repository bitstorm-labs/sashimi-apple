import XCTest
@testable import Sashimi

final class KeychainHelperTests: XCTestCase {

    // Use a unique test key prefix to avoid conflicts
    private let testKeyPrefix = "test_sashimi_"

    override func tearDown() {
        super.tearDown()
        // Clean up test keys after each test
        KeychainHelper.delete(forKey: "\(testKeyPrefix)token")
        KeychainHelper.delete(forKey: "\(testKeyPrefix)user")
        KeychainHelper.delete(forKey: "\(testKeyPrefix)empty")
    }

    // MARK: - Save and Retrieve Tests

    func testSaveAndRetrieveValue() {
        let key = "\(testKeyPrefix)token"
        let value = "test-access-token-12345"

        let saveResult = KeychainHelper.save(value, forKey: key)
        XCTAssertTrue(saveResult, "Save should succeed")

        let retrieved = KeychainHelper.get(forKey: key)
        XCTAssertEqual(retrieved, value, "Retrieved value should match saved value")
    }

    func testSaveOverwritesExistingValue() {
        let key = "\(testKeyPrefix)token"
        let originalValue = "original-token"
        let newValue = "new-token"

        // Save original
        XCTAssertTrue(KeychainHelper.save(originalValue, forKey: key))
        XCTAssertEqual(KeychainHelper.get(forKey: key), originalValue)

        // Overwrite with new value
        XCTAssertTrue(KeychainHelper.save(newValue, forKey: key))
        XCTAssertEqual(KeychainHelper.get(forKey: key), newValue)
    }

    func testRetrieveNonExistentKey() {
        let key = "\(testKeyPrefix)nonexistent_key_12345"

        let retrieved = KeychainHelper.get(forKey: key)
        XCTAssertNil(retrieved, "Non-existent key should return nil")
    }

    // MARK: - Delete Tests

    func testDeleteExistingKey() {
        let key = "\(testKeyPrefix)token"
        let value = "token-to-delete"

        // Save first
        XCTAssertTrue(KeychainHelper.save(value, forKey: key))
        XCTAssertNotNil(KeychainHelper.get(forKey: key))

        // Delete
        let deleteResult = KeychainHelper.delete(forKey: key)
        XCTAssertTrue(deleteResult, "Delete should succeed")

        // Verify deleted
        XCTAssertNil(KeychainHelper.get(forKey: key), "Deleted key should return nil")
    }

    func testDeleteNonExistentKey() {
        let key = "\(testKeyPrefix)nonexistent_delete_key"

        // Should still return true (or not crash)
        let deleteResult = KeychainHelper.delete(forKey: key)
        XCTAssertTrue(deleteResult, "Deleting non-existent key should succeed")
    }

    // MARK: - Edge Cases

    func testSaveEmptyString() {
        let key = "\(testKeyPrefix)empty"
        let value = ""

        let saveResult = KeychainHelper.save(value, forKey: key)
        XCTAssertTrue(saveResult, "Saving empty string should succeed")

        let retrieved = KeychainHelper.get(forKey: key)
        XCTAssertEqual(retrieved, "", "Retrieved empty string should match")
    }

    func testSaveLongValue() {
        let key = "\(testKeyPrefix)token"
        let value = String(repeating: "a", count: 10000)

        let saveResult = KeychainHelper.save(value, forKey: key)
        XCTAssertTrue(saveResult, "Saving long value should succeed")

        let retrieved = KeychainHelper.get(forKey: key)
        XCTAssertEqual(retrieved, value, "Retrieved long value should match")
    }

    func testSaveSpecialCharacters() {
        let key = "\(testKeyPrefix)token"
        let value = "token!@#$%^&*()_+-=[]{}|;':\",./<>?"

        let saveResult = KeychainHelper.save(value, forKey: key)
        XCTAssertTrue(saveResult, "Saving special characters should succeed")

        let retrieved = KeychainHelper.get(forKey: key)
        XCTAssertEqual(retrieved, value, "Special characters should be preserved")
    }

    func testSaveUnicodeValue() {
        let key = "\(testKeyPrefix)user"
        let value = "用户名 🎬 émoji"

        let saveResult = KeychainHelper.save(value, forKey: key)
        XCTAssertTrue(saveResult, "Saving unicode value should succeed")

        let retrieved = KeychainHelper.get(forKey: key)
        XCTAssertEqual(retrieved, value, "Unicode characters should be preserved")
    }

    // MARK: - Multiple Keys Tests

    func testMultipleKeys() {
        let key1 = "\(testKeyPrefix)token"
        let key2 = "\(testKeyPrefix)user"
        let value1 = "access-token"
        let value2 = "user-id"

        // Save both
        XCTAssertTrue(KeychainHelper.save(value1, forKey: key1))
        XCTAssertTrue(KeychainHelper.save(value2, forKey: key2))

        // Retrieve both
        XCTAssertEqual(KeychainHelper.get(forKey: key1), value1)
        XCTAssertEqual(KeychainHelper.get(forKey: key2), value2)

        // Delete one, other should remain
        XCTAssertTrue(KeychainHelper.delete(forKey: key1))
        XCTAssertNil(KeychainHelper.get(forKey: key1))
        XCTAssertEqual(KeychainHelper.get(forKey: key2), value2)
    }
}
