import XCTest
@testable import Sashimi

/// A bandwidth probe never outlives the work it belongs to. Cancelling the
/// probe (a server switch replaces it) stops its in-flight download, and a
/// probe a test started cannot retry into a later test's stub (#881 merge
/// queue: a stray BitrateTest landed in RemoteControlClientTests).
///
/// The two `testIsolation…` cases run in order (XCTest sorts by name): the
/// first leaves a failing probe behind, the second listens for its retry.
final class BandwidthProbeIsolationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        JellyfinRouteStub.reset()
        super.tearDown()
    }

    func testCancellingTheProbeStopsItsDownload() async throws {
        let server = try XCTUnwrap(URL(string: "https://probe-cancel.example"))
        let store = BandwidthMeasurementStore()
        let client = JellyfinClient(serverURL: server, accessToken: "token", userId: "user", bandwidthStore: store)
        JellyfinRouteStub.routes["GET /Playback/BitrateTest"] = (200, String(repeating: "0", count: 1_100_000))
        JellyfinRouteStub.delays["GET /Playback/BitrateTest"] = 5

        await client.startBandwidthMeasurement()
        try await waitForBitrateTest(count: 1)
        let probe = try XCTUnwrap(store.probe(for: server))

        let start = ContinuousClock.now
        probe.cancel()
        await probe.value
        let stopped = ContinuousClock.now - start

        XCTAssertLessThan(stopped, .seconds(2), "a cancelled probe must stop its download, not wait out the response")
        XCTAssertNil(store.measurement(for: server))
    }

    func testIsolation1LeavesAFailingProbeBehind() async throws {
        // 404: the attempt fails and the probe schedules a retry 3 s later.
        let server = try XCTUnwrap(URL(string: "https://probe-leak.example"))
        await JellyfinClient(serverURL: server, accessToken: "token", userId: "user").startBandwidthMeasurement()
        try await waitForBitrateTest(count: 1)
    }

    func testIsolation2NoEarlierProbeReachesThisTestsStub() async throws {
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/Playback/BitrateTest").count, 0,
                       "a probe from an earlier test retried into this test's stub")
    }

    private func waitForBitrateTest(count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while JellyfinRouteStub.requests("GET", "/Playback/BitrateTest").count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(JellyfinRouteStub.requests("GET", "/Playback/BitrateTest").count, count)
    }
}
