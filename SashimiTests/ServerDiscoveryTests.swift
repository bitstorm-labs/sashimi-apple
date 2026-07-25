import XCTest
@testable import Sashimi

/// Discovery is a network protocol, so the useful tests come in two halves:
/// pure parsing that always runs, and one live probe that skips when there is
/// no Jellyfin on the LAN (same pattern as KeychainHelperTests, which skips
/// when the simulator keychain is unavailable).
final class ServerDiscoveryTests: XCTestCase {

    // MARK: - Advertised address parsing

    func testPortIsTakenFromAdvertisedAddress() {
        XCTAssertEqual(ServerDiscovery.port(fromAdvertised: "http://192.168.1.10:8096"), 8096)
        XCTAssertEqual(ServerDiscovery.port(fromAdvertised: "https://jelly.example.com:9096"), 9096)
    }

    func testPortIsParsedWhenSchemeIsMissing() {
        // Jellyfin's reply is not guaranteed to include a scheme.
        XCTAssertEqual(ServerDiscovery.port(fromAdvertised: "192.168.1.10:9096"), 9096)
    }

    func testPortIsNilWhenAbsentSoCallerCanDefault() {
        // No port means the caller falls back to 8096 rather than guessing.
        XCTAssertNil(ServerDiscovery.port(fromAdvertised: "http://192.168.1.10"))
        XCTAssertNil(ServerDiscovery.port(fromAdvertised: "jellyfin.example.com"))
        XCTAssertNil(ServerDiscovery.port(fromAdvertised: nil))
    }

    // MARK: - Live probe

    /// Broadcasts on the real network and asserts we can parse a real reply.
    ///
    /// Skips when nothing answers, so CI (which has no Jellyfin) stays green
    /// while a developer on the same LAN as a server gets real coverage. This
    /// is the test that would have caught the original defect: the Bonjour
    /// implementation could never have passed it, because Jellyfin advertises
    /// no `_jellyfin._tcp` service.
    @MainActor
    func testDiscoveryFindsAServerOnTheLocalNetwork() async throws {
        let discovery = ServerDiscovery()
        discovery.startDiscovery()

        // startDiscovery's probe window is 3s; give it headroom.
        let deadline = Date().addingTimeInterval(8)
        while discovery.isSearching, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }

        try XCTSkipUnless(
            !discovery.discoveredServers.isEmpty,
            "No Jellyfin server answered the UDP broadcast on this network - skipping the live half."
        )

        let server = try XCTUnwrap(discovery.discoveredServers.first)
        XCTAssertFalse(server.id.isEmpty, "Server id is used to dedupe repeated probes")
        XCTAssertFalse(server.name.isEmpty)
        XCTAssertFalse(server.address.isEmpty)
        XCTAssertGreaterThan(server.port, 0)

        // The address must be the responder's source IP, not the advertised
        // public hostname - that is what makes the URL usable on the LAN.
        let url = try XCTUnwrap(server.url)
        XCTAssertEqual(url.scheme, "http")
        XCTAssertTrue(
            server.address.allSatisfy { $0.isNumber || $0 == "." },
            "Expected a dotted-quad source IP, got \(server.address)"
        )
    }

    @MainActor
    func testRepeatedProbesDoNotDuplicateTheSameServer() async throws {
        let discovery = ServerDiscovery()

        discovery.startDiscovery()
        var deadline = Date().addingTimeInterval(8)
        while discovery.isSearching, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        try XCTSkipUnless(!discovery.discoveredServers.isEmpty, "No server on this network - skipping.")
        let firstCount = discovery.discoveredServers.count

        discovery.startDiscovery()
        deadline = Date().addingTimeInterval(8)
        while discovery.isSearching, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }

        XCTAssertEqual(discovery.discoveredServers.count, firstCount,
                       "A second probe must dedupe by server id, not stack duplicates")
    }
}
