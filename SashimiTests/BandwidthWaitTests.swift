import XCTest
@testable import Sashimi

/// #881: the wait for a bandwidth probe before Auto playback is bounded by its
/// timeout, not by however long the probe round runs.
final class BandwidthWaitTests: XCTestCase {
    func testWaitReturnsAtTheTimeoutWhileTheProbeIsStillRunning() async throws {
        let server = try XCTUnwrap(URL(string: "https://bandwidth-wait.example"))
        let store = BandwidthMeasurementStore()
        let client = JellyfinClient(serverURL: server, accessToken: "token", userId: "user", bandwidthStore: store)
        // A probe round that outlives the wait by far (failed attempts retry
        // for over a minute). It is not ours to cancel.
        let probe = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        store.replaceProbe(for: server, with: probe)
        defer { probe.cancel() }

        let start = ContinuousClock.now
        await client.waitForAnyBandwidthMeasurement(upTo: .milliseconds(200))
        let waited = ContinuousClock.now - start

        XCTAssertLessThan(waited, .seconds(2), "the wait must end at its timeout, not when the probe does")
        XCTAssertFalse(probe.isCancelled, "timing out must not cancel the session's probe")
    }

    func testWaitReturnsAsSoonAsTheProbeFinishes() async throws {
        let server = try XCTUnwrap(URL(string: "https://bandwidth-wait-fast.example"))
        let store = BandwidthMeasurementStore()
        let client = JellyfinClient(serverURL: server, accessToken: "token", userId: "user", bandwidthStore: store)
        let probe = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(50)) }
        store.replaceProbe(for: server, with: probe)

        let start = ContinuousClock.now
        await client.waitForAnyBandwidthMeasurement(upTo: .seconds(10))
        let waited = ContinuousClock.now - start

        XCTAssertLessThan(waited, .seconds(5), "a finished probe ends the wait without sitting out the timeout")
    }
}
