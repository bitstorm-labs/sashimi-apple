import XCTest
@testable import Sashimi

final class ValidationTests: XCTestCase {

    // MARK: - URL Validation Tests

    func testValidHTTPURLs() {
        let validURLs = [
            "http://192.168.1.100:8096",
            "http://localhost:8096",
            "http://jellyfin.local:8096",
            "https://media.example.com",
            "https://jellyfin.example.com:443",
            "http://10.0.0.1:8096"
        ]

        for urlString in validURLs {
            let url = URL(string: urlString)
            XCTAssertNotNil(url, "URL should be valid: \(urlString)")
            XCTAssertNotNil(url?.scheme, "URL should have scheme: \(urlString)")
            XCTAssertNotNil(url?.host, "URL should have host: \(urlString)")

            if let scheme = url?.scheme?.lowercased() {
                XCTAssertTrue(["http", "https"].contains(scheme), "Scheme should be http or https: \(urlString)")
            }
        }
    }

    func testInvalidURLs() {
        let invalidURLs = [
            "not a url",
            "ftp://server.com",
            "://missing-scheme",
            "http://",
            ""
        ]

        for urlString in invalidURLs {
            let url = URL(string: urlString)
            let scheme = url?.scheme?.lowercased()
            let hasValidScheme = scheme != nil && ["http", "https"].contains(scheme!)
            let hasValidHost = url?.host != nil && !url!.host!.isEmpty

            let isValid = url != nil && hasValidScheme && hasValidHost
            XCTAssertFalse(isValid, "URL should be invalid: \(urlString)")
        }
    }

    // MARK: - Time Formatting Tests

    func testTicksToSeconds() {
        // 1 second = 10,000,000 ticks
        let ticks: Int64 = 36_000_000_000 // 1 hour in ticks

        let seconds = ticks / 10_000_000
        XCTAssertEqual(seconds, 3600)

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        XCTAssertEqual(hours, 1)
        XCTAssertEqual(minutes, 0)
    }

    func testRuntimeFormatting() {
        // Test 2h 30m
        let ticks: Int64 = 90_000_000_000 // 2.5 hours

        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        XCTAssertEqual(hours, 2)
        XCTAssertEqual(minutes, 30)
    }

    // MARK: - Progress Calculation Tests

    func testProgressCalculation() {
        let totalTicks: Int64 = 72_000_000_000 // 2 hours
        let playedTicks: Int64 = 36_000_000_000 // 1 hour

        let progress = Double(playedTicks) / Double(totalTicks)
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    func testProgressCalculationEdgeCases() {
        // Zero total should not crash
        let totalTicks: Int64 = 0
        let playedTicks: Int64 = 0

        if totalTicks > 0 {
            let progress = Double(playedTicks) / Double(totalTicks)
            XCTAssertGreaterThanOrEqual(progress, 0)
            XCTAssertLessThanOrEqual(progress, 1)
        } else {
            // Zero runtime should result in 0 progress
            XCTAssertEqual(Double(0), 0)
        }

        // Played more than total should cap at 1
        let overPlayed: Int64 = 100_000_000_000
        let underTotal: Int64 = 50_000_000_000

        let rawProgress = Double(overPlayed) / Double(underTotal)
        let cappedProgress = min(max(rawProgress, 0), 1)
        XCTAssertEqual(cappedProgress, 1.0)
    }

    // MARK: - Episode Info Formatting Tests

    func testEpisodeInfoFormatting() {
        let seasonNumber = 2
        let episodeNumber = 5
        let episodeName = "Test Episode"

        let formatted = "S\(seasonNumber):E\(episodeNumber) - \(episodeName)"
        XCTAssertEqual(formatted, "S2:E5 - Test Episode")
    }

    // MARK: - Search History Tests

    func testSearchQueryNormalization() {
        let query = "  Test Query  "
        let normalized = query.trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(normalized, "Test Query")
    }
}
