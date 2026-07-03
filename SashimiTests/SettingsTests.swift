import XCTest
@testable import Sashimi

final class SettingsTests: XCTestCase {

    // MARK: - PlaybackSettings Tests

    @MainActor
    func testPlaybackSettingsDefaults() {
        let settings = PlaybackSettings.shared

        // Test default values exist and are reasonable
        XCTAssertTrue(settings.autoPlayNextEpisode)
        XCTAssertFalse(settings.autoSkipIntro)
        XCTAssertFalse(settings.autoSkipCredits)
        XCTAssertEqual(settings.resumeThresholdSeconds, 30)
    }

    // MARK: - ParentalControlsManager Tests

    @MainActor
    func testParentalControlsShouldHideItem() {
        let controls = ParentalControlsManager.shared

        // Store original value
        let originalRating = controls.maxContentRating
        let originalHideUnrated = controls.hideUnrated

        // Test when no restriction is set
        controls.maxContentRating = .any
        XCTAssertFalse(controls.shouldHideItem(withRating: "R"))
        XCTAssertFalse(controls.shouldHideItem(withRating: "NC-17"))

        // Test when PG-13 is the max
        controls.maxContentRating = .pg13
        XCTAssertFalse(controls.shouldHideItem(withRating: "G"))
        XCTAssertFalse(controls.shouldHideItem(withRating: "PG"))
        XCTAssertFalse(controls.shouldHideItem(withRating: "PG-13"))
        XCTAssertTrue(controls.shouldHideItem(withRating: "R"))
        XCTAssertTrue(controls.shouldHideItem(withRating: "NC-17"))

        // Test unrated content
        controls.hideUnrated = true
        XCTAssertTrue(controls.shouldHideItem(withRating: nil))

        controls.hideUnrated = false
        XCTAssertFalse(controls.shouldHideItem(withRating: nil))

        // Restore original values
        controls.maxContentRating = originalRating
        controls.hideUnrated = originalHideUnrated
    }

    // MARK: - CertificateTrustSettings Tests

    @MainActor
    func testCertificateTrustHostManagement() {
        let certSettings = CertificateTrustSettings.shared

        // Store original state
        let originalHosts = certSettings.trustedHosts

        // Test adding a host
        let testHost = "test.local.server"
        certSettings.trustHost(testHost)
        XCTAssertTrue(certSettings.isHostTrusted(testHost))

        // Test removing a host
        certSettings.untrustHost(testHost)
        XCTAssertFalse(certSettings.isHostTrusted(testHost))

        // Restore original state
        certSettings.trustedHosts = originalHosts
    }

    @MainActor
    func testUntrustHostDropsPinnedFingerprint() {
        let certSettings = CertificateTrustSettings.shared
        let defaults = UserDefaults.standard
        let testHost = "pinned.local.server"

        let originalHosts = certSettings.trustedHosts
        let originalPins = defaults.dictionary(forKey: CertificateTrustKeys.fingerprints) as? [String: String]

        certSettings.trustHost(testHost)
        var pins = originalPins ?? [:]
        pins[testHost] = "abc123"
        defaults.set(pins, forKey: CertificateTrustKeys.fingerprints)

        certSettings.untrustHost(testHost)
        let remaining = defaults.dictionary(forKey: CertificateTrustKeys.fingerprints) as? [String: String]
        XCTAssertNil(remaining?[testHost])

        // Restore original state
        certSettings.trustedHosts = originalHosts
        if let originalPins {
            defaults.set(originalPins, forKey: CertificateTrustKeys.fingerprints)
        } else {
            defaults.removeObject(forKey: CertificateTrustKeys.fingerprints)
        }
    }

    func testLegacyGlobalAllowanceMigratesToChallengedHost() {
        let defaults = UserDefaults.standard
        let listKey = "test_selfSignedAllowedHosts"
        let legacyKey = "test_allowSelfSignedCerts"
        defaults.removeObject(forKey: listKey)
        defaults.set(true, forKey: legacyKey)

        // Legacy global flag is honored once and migrated to the host
        XCTAssertTrue(CertificateValidationDelegate.hostAllowance(host: "server.test", listKey: listKey, legacyKey: legacyKey))
        XCTAssertFalse(defaults.bool(forKey: legacyKey), "legacy flag should be cleared after migration")
        XCTAssertEqual(defaults.array(forKey: listKey) as? [String], ["server.test"])

        // After migration the allowance is scoped: same host yes, others no
        XCTAssertTrue(CertificateValidationDelegate.hostAllowance(host: "server.test", listKey: listKey, legacyKey: legacyKey))
        XCTAssertFalse(CertificateValidationDelegate.hostAllowance(host: "other.test", listKey: listKey, legacyKey: legacyKey))

        defaults.removeObject(forKey: listKey)
        defaults.removeObject(forKey: legacyKey)
    }

    func testHostAllowanceFalseWithoutEntryOrLegacyFlag() {
        let defaults = UserDefaults.standard
        let listKey = "test_expiredAllowedHosts"
        let legacyKey = "test_allowExpiredCerts"
        defaults.removeObject(forKey: listKey)
        defaults.removeObject(forKey: legacyKey)

        XCTAssertFalse(CertificateValidationDelegate.hostAllowance(host: "server.test", listKey: listKey, legacyKey: legacyKey))
    }

    // MARK: - LibrarySortOption Tests

    func testLibrarySortOptionRawValues() {
        XCTAssertEqual(LibrarySortOption.name.rawValue, "SortName")
        XCTAssertEqual(LibrarySortOption.dateAdded.rawValue, "DateCreated")
        XCTAssertEqual(LibrarySortOption.releaseDate.rawValue, "PremiereDate")
        XCTAssertEqual(LibrarySortOption.rating.rawValue, "CommunityRating")
        XCTAssertEqual(LibrarySortOption.runtime.rawValue, "Runtime")
    }

    func testSortOrderRawValues() {
        XCTAssertEqual(SortOrder.ascending.rawValue, "Ascending")
        XCTAssertEqual(SortOrder.descending.rawValue, "Descending")
    }
}
