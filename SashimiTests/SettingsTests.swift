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

        // Restore original state. trustedHosts is a read-only mirror of the
        // defaults now, so restore through the defaults and re-read.
        UserDefaults.standard.set(Array(originalHosts), forKey: CertificateTrustKeys.trustedHosts)
        certSettings.reloadFromDefaults()
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
        UserDefaults.standard.set(Array(originalHosts), forKey: CertificateTrustKeys.trustedHosts)
        certSettings.reloadFromDefaults()
        if let originalPins {
            defaults.set(originalPins, forKey: CertificateTrustKeys.fingerprints)
        } else {
            defaults.removeObject(forKey: CertificateTrustKeys.fingerprints)
        }
    }

    @MainActor
    func testAToggleDoesNotClobberAHostAddedBehindItsBack() {
        // The bug: CertificateTrustSettings loaded its Sets once in init, and a
        // didSet wrote the whole Set back. CertificateValidationDelegate also
        // writes those keys, from the URLSession delegate queue, when it
        // migrates a legacy flag onto a host. So a toggle made afterwards
        // overwrote the delegate's addition from a stale in-memory copy --
        // silently revoking the current server's allowance, after which every
        // request to it failed.
        let certSettings = CertificateTrustSettings.shared
        let defaults = UserDefaults.standard
        let key = CertificateTrustKeys.selfSignedHosts
        let original = defaults.array(forKey: key) as? [String]

        defaults.set([String](), forKey: key)
        certSettings.reloadFromDefaults()

        // Simulate the delegate adding a host directly to the defaults while
        // this object holds an older snapshot.
        defaults.set(["added.behind.our.back"], forKey: key)

        // Now a normal UI toggle for a different host.
        certSettings.setSelfSignedAllowed(true, host: "user.toggled.host")

        let stored = Set((defaults.array(forKey: key) as? [String]) ?? [])
        XCTAssertTrue(stored.contains("added.behind.our.back"), "Concurrent addition must survive a later toggle")
        XCTAssertTrue(stored.contains("user.toggled.host"))

        if let original {
            defaults.set(original, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        certSettings.reloadFromDefaults()
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
