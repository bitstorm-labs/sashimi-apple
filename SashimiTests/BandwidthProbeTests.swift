import XCTest
@testable import Sashimi

final class BandwidthProbeTests: XCTestCase {
    func testSteadyStateRate() {
        // 25 MB over the 4s steady-state window = 50 Mbps.
        XCTAssertEqual(SustainedBandwidthProbe.bitsPerSecond(measuredBytes: 25_000_000, seconds: 4.0), 50_000_000)
    }

    func testSlowLinkRate() {
        // 2.4 MB over 4s ≈ 4.8 Mbps — the kind of weak link the old burst probe
        // still handled; the sustained probe must too.
        XCTAssertEqual(SustainedBandwidthProbe.bitsPerSecond(measuredBytes: 2_400_000, seconds: 4.0), 4_800_000)
    }

    func testTooBriefIsRejected() {
        // A sample shorter than the floor can't be trusted (it may still be
        // inside the ramp) — nil so Auto falls back rather than over-reading.
        XCTAssertNil(SustainedBandwidthProbe.bitsPerSecond(measuredBytes: 30_000_000, seconds: 0.3))
    }

    func testNoBytesIsRejected() {
        XCTAssertNil(SustainedBandwidthProbe.bitsPerSecond(measuredBytes: 0, seconds: 4.0))
    }
}
