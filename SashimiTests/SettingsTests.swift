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
