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

    // MARK: - Fast links (#602)

    func testFastLinkThatFinishesInsideTheWarmupIsMeasured() {
        // Gigabit LAN: the whole 25 MB sample lands in 0.2 s, before the 1 s
        // warm-up ends, so there is no steady-state window at all. That used
        // to be nil -> "failed" -> three more probes, every launch.
        let reading = SustainedBandwidthProbe.bitsPerSecond(
            totalBytes: 25_000_000, totalSeconds: 0.2,
            steadyBytes: 0, steadySeconds: 0,
            transferCompleted: true
        )
        XCTAssertEqual(reading, 1_000_000_000)
    }

    func testTransferEndingJustAfterTheWarmupIsTimedWhole() {
        // 25 MB in 1.2 s: the steady window is only 0.2 s (too brief), but the
        // sample completed, so the whole transfer is the reading.
        let reading = SustainedBandwidthProbe.bitsPerSecond(
            totalBytes: 25_000_000, totalSeconds: 1.25,
            steadyBytes: 4_000_000, steadySeconds: 0.25,
            transferCompleted: true
        )
        XCTAssertEqual(reading, 160_000_000)
    }

    func testSteadyStateWindowWinsWhenLongEnough() {
        let reading = SustainedBandwidthProbe.bitsPerSecond(
            totalBytes: 12_000_000, totalSeconds: 5,
            steadyBytes: 10_000_000, steadySeconds: 4,
            transferCompleted: false
        )
        XCTAssertEqual(reading, 20_000_000)
    }

    func testTransferCutShortByAnErrorIsNotAMeasurement() {
        // Connection dropped 0.3 s in: nothing completed, nothing steady.
        XCTAssertNil(SustainedBandwidthProbe.bitsPerSecond(
            totalBytes: 3_000_000, totalSeconds: 0.3,
            steadyBytes: 0, steadySeconds: 0,
            transferCompleted: false
        ))
    }

    func testTinyCompletedBodyIsNotAMeasurement() {
        // A short error page that "completed" is not a bandwidth sample.
        XCTAssertNil(SustainedBandwidthProbe.bitsPerSecond(
            totalBytes: 2_000, totalSeconds: 0.01,
            steadyBytes: 0, steadySeconds: 0,
            transferCompleted: true
        ))
    }

    func testFastLinkReadingClampsToTheAutoCeiling() {
        let reading = SustainedBandwidthProbe.bitsPerSecond(
            totalBytes: 25_000_000, totalSeconds: 0.2,
            steadyBytes: 0, steadySeconds: 0,
            transferCompleted: true
        )
        XCTAssertEqual(
            PlaybackSelection.autoBitrateCap(measuredBitrate: reading, isLocalServer: true, isMeteredNetwork: false),
            PlaybackSelection.maximumMeasuredBitrateCap
        )
    }

    // MARK: - Data spent per round (#602)

    func testOneSampleIsAtMostTwentyFiveMegabytes() {
        XCTAssertLessThanOrEqual(SustainedBandwidthProbe.defaultMaxBytes, 25_000_000)
    }

    func testRetriesStopOnceTheDataBudgetIsSpent() {
        XCTAssertTrue(JellyfinClient.bandwidthProbeBudgetAllowsAnotherAttempt(bytesSpent: 0))
        XCTAssertTrue(JellyfinClient.bandwidthProbeBudgetAllowsAnotherAttempt(bytesSpent: 20_000_000))
        XCTAssertFalse(JellyfinClient.bandwidthProbeBudgetAllowsAnotherAttempt(bytesSpent: 30_000_000))
        // The old behaviour: four 50 MB probes. The budget never allows that.
        XCTAssertLessThanOrEqual(JellyfinClient.bandwidthProbeByteBudget, 50_000_000)
    }

    // MARK: - Metered networks (#602)

    func testMovingOntoCellularInvalidatesTheMeasurement() {
        XCTAssertTrue(NetworkConnectionMonitor.invalidatesMeasurement(
            hadPath: true, wasWired: false, isWired: false, wasMetered: false, isMetered: true
        ))
        XCTAssertTrue(NetworkConnectionMonitor.invalidatesMeasurement(
            hadPath: true, wasWired: false, isWired: false, wasMetered: true, isMetered: false
        ))
    }

    func testWiredWirelessFlipStillInvalidates() {
        XCTAssertTrue(NetworkConnectionMonitor.invalidatesMeasurement(
            hadPath: true, wasWired: true, isWired: false, wasMetered: false, isMetered: false
        ))
    }

    func testInitialPathAndUnchangedPathDoNotInvalidate() {
        XCTAssertFalse(NetworkConnectionMonitor.invalidatesMeasurement(
            hadPath: false, wasWired: false, isWired: true, wasMetered: false, isMetered: true
        ))
        XCTAssertFalse(NetworkConnectionMonitor.invalidatesMeasurement(
            hadPath: true, wasWired: false, isWired: false, wasMetered: false, isMetered: false
        ))
    }

    func testCapSourceNamesTheMeteredDefault() {
        let skipped = JellyfinClient.BandwidthStatus(
            measuredBitrate: nil, cap: 4_000_000, isLocalServer: false, isWired: false,
            skippedOnMeteredNetwork: true
        )
        XCTAssertEqual(skipped.capSource, "default-metered")
        let measured = JellyfinClient.BandwidthStatus(
            measuredBitrate: 50_000_000, cap: 42_500_000, isLocalServer: false, isWired: false
        )
        XCTAssertEqual(measured.capSource, "measured")
    }
}
