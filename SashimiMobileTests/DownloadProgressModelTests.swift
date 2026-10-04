import XCTest
@testable import SashimiMobile

final class DownloadProgressModelTests: XCTestCase {
    private static let fortyTwoMinutes: Int64 = 42 * 60 * 10_000_000

    // MARK: - Size estimate

    func testTierEstimateIsVideoPlusAudioBitrateTimesRuntime() {
        // Medium asks for 7.808 Mbps video + 192 kbps audio = 8 Mbps.
        // 2520 s x 8_000_000 / 8 = 2.52 GB.
        XCTAssertEqual(
            DownloadSizeEstimate.expectedBytes(quality: .medium, runTimeTicks: Self.fortyTwoMinutes),
            2_520_000_000
        )
    }

    func testTierEstimateIsCappedByTheSourceVideoBitrate() {
        // A 1.2 Mbps source can't come out at Medium's 7.8 Mbps: the server
        // caps the video at the source's. (1_200_000 + 192_000) x 2520 / 8.
        XCTAssertEqual(
            DownloadSizeEstimate.expectedBytes(
                quality: .medium,
                runTimeTicks: Self.fortyTwoMinutes,
                sourceBitrate: 1_500_000,
                sourceVideoBitrate: 1_200_000
            ),
            438_480_000
        )
        // Only the overall bitrate known: it stands in for the video's.
        XCTAssertEqual(
            DownloadSizeEstimate.expectedBitrate(quality: .low, sourceBitrate: 2_000_000),
            2_000_000 + 128_000
        )
        // A source above the tier leaves the tier's own bitrate.
        XCTAssertEqual(
            DownloadSizeEstimate.expectedBitrate(quality: .low, sourceBitrate: 40_000_000, sourceVideoBitrate: 38_000_000),
            4_000_000
        )
    }

    func testOriginalEstimateIsTheSourceBitrateOrUnknown() {
        XCTAssertNil(DownloadSizeEstimate.expectedBytes(quality: .original, runTimeTicks: Self.fortyTwoMinutes))
        XCTAssertEqual(
            DownloadSizeEstimate.expectedBytes(
                quality: .original, runTimeTicks: Self.fortyTwoMinutes, sourceBitrate: 10_000_000
            ),
            3_150_000_000
        )
    }

    func testEstimateNeedsARuntime() {
        XCTAssertNil(DownloadSizeEstimate.expectedBytes(quality: .high, runTimeTicks: nil))
        XCTAssertNil(DownloadSizeEstimate.expectedBytes(quality: .high, runTimeTicks: 0))
    }

    func testEstimateFromPersistedInput() {
        let input = DownloadEstimateInput(
            quality: DownloadQuality.medium.rawValue,
            runTimeTicks: Self.fortyTwoMinutes,
            sourceBitrate: nil,
            sourceVideoBitrate: 1_200_000
        )
        XCTAssertEqual(DownloadSizeEstimate.expectedBytes(for: input), 438_480_000)
        XCTAssertNil(DownloadSizeEstimate.expectedBytes(for: DownloadEstimateInput()))
    }

    // MARK: - Fraction, clamping and growth

    func testExactTotalWinsOverTheEstimateAndIsNotMarkedEstimated() {
        let display = DownloadProgressDisplay.make(
            receivedBytes: 250, exactTotalBytes: 1_000, estimatedTotalBytes: 5_000
        )
        XCTAssertEqual(display.fraction, 0.25)
        XCTAssertEqual(display.totalBytes, 1_000)
        XCTAssertFalse(display.isEstimated)
    }

    func testUnknownLengthUsesTheEstimate() {
        // -1 is what URLSession reports for a transcode.
        let display = DownloadProgressDisplay.make(
            receivedBytes: 182, exactTotalBytes: -1, estimatedTotalBytes: 420
        )
        XCTAssertEqual(try XCTUnwrap(display.fraction), 182.0 / 420.0, accuracy: 0.0001)
        XCTAssertEqual(display.totalBytes, 420)
        XCTAssertTrue(display.isEstimated)
    }

    func testNoLengthAndNoEstimateHasNoFraction() {
        let display = DownloadProgressDisplay.make(receivedBytes: 182, exactTotalBytes: -1, estimatedTotalBytes: nil)
        XCTAssertNil(display.fraction)
        XCTAssertNil(display.totalBytes)
        XCTAssertEqual(display.receivedBytes, 182)
    }

    func testEstimateGrowsOnceTheBytesPassIt() throws {
        // At the estimate itself: 95%, and the total has moved ahead of it.
        let atEstimate = DownloadProgressDisplay.make(
            receivedBytes: 1_000, exactTotalBytes: nil, estimatedTotalBytes: 1_000
        )
        XCTAssertEqual(try XCTUnwrap(atEstimate.fraction), 0.95, accuracy: 0.0001)
        XCTAssertEqual(atEstimate.totalBytes, 1_053)

        // Five times the estimate: capped at 99%, total still ahead of the bytes.
        let farPast = DownloadProgressDisplay.make(
            receivedBytes: 5_000, exactTotalBytes: nil, estimatedTotalBytes: 1_000
        )
        XCTAssertEqual(farPast.fraction, 0.99)
        XCTAssertGreaterThan(try XCTUnwrap(farPast.totalBytes), 5_000)
    }

    func testFractionNeverPassesNinetyNinePercentAndNeverGoesBackwards() throws {
        var previousFraction = -1.0
        var previousTotal: Int64 = 0
        for received in stride(from: Int64(0), through: 30_000, by: 50) {
            let display = DownloadProgressDisplay.make(
                receivedBytes: received, exactTotalBytes: nil, estimatedTotalBytes: 10_000
            )
            let fraction = try XCTUnwrap(display.fraction)
            let total = try XCTUnwrap(display.totalBytes)
            XCTAssertLessThanOrEqual(fraction, 0.99, "at \(received)")
            XCTAssertGreaterThanOrEqual(fraction, previousFraction, "at \(received)")
            XCTAssertGreaterThanOrEqual(total, previousTotal, "at \(received)")
            XCTAssertGreaterThan(total, received, "bytes left must stay positive at \(received)")
            previousFraction = fraction
            previousTotal = total
        }
    }

    func testBarKeepsMovingBetweenTheEstimateAndTheCap() throws {
        // Under-estimated by 30%: the bar must not have frozen on the way.
        let fractions = try [9_000, 10_000, 11_500, 13_000].map { received in
            try XCTUnwrap(DownloadProgressDisplay.make(
                receivedBytes: Int64(received), exactTotalBytes: nil, estimatedTotalBytes: 10_000
            ).fraction)
        }
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(Set(fractions).count, fractions.count, "\(fractions)")
        XCTAssertLessThan(try XCTUnwrap(fractions.last), 0.99)
    }

    func testExactTotalIsCappedAtNinetyNinePercentUntilCompletion() {
        let display = DownloadProgressDisplay.make(receivedBytes: 1_000, exactTotalBytes: 1_000, estimatedTotalBytes: nil)
        XCTAssertEqual(display.fraction, 0.99)
        XCTAssertEqual(display.totalBytes, 1_000)
    }

    // MARK: - Speed smoothing

    func testSpeedIsHiddenUntilThereIsEnoughData() {
        var tracker = DownloadSpeedTracker()
        tracker.record(totalBytes: 1_000, at: 0)
        XCTAssertNil(tracker.bytesPerSecond)
        tracker.record(totalBytes: 1_001_000, at: 1)
        tracker.record(totalBytes: 2_001_000, at: 2)
        XCTAssertNil(tracker.bytesPerSecond, "two samples are not enough")
        tracker.record(totalBytes: 3_001_000, at: 3)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 1_000_000, accuracy: 1)
    }

    func testSpeedIsSmoothedNotInstantaneous() throws {
        var tracker = Self.steadyTracker(bytesPerSecond: 1_000_000, seconds: 3)
        // One burst at double speed moves the average by 30%, not 100%.
        tracker.record(totalBytes: 3_001_000 + 2_000_000, at: 4)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 1_300_000, accuracy: 1)
    }

    func testSamplesCloserThanTheIntervalAreFoldedIntoTheNextOne() throws {
        var tracker = Self.steadyTracker(bytesPerSecond: 1_000_000, seconds: 3)
        tracker.record(totalBytes: 3_501_000, at: 3.5)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 1_000_000, accuracy: 1)
        tracker.record(totalBytes: 4_001_000, at: 4)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 1_000_000, accuracy: 1)
    }

    func testWaitingForTheFirstBytesIsNotCountedAsSpeed() throws {
        var tracker = DownloadSpeedTracker()
        // 20 s of the server starting ffmpeg, then steady bytes.
        for second in 0..<20 { tracker.record(totalBytes: 0, at: Double(second)) }
        tracker.record(totalBytes: 1_000, at: 20)
        tracker.record(totalBytes: 1_001_000, at: 21)
        tracker.record(totalBytes: 2_001_000, at: 22)
        tracker.record(totalBytes: 3_001_000, at: 23)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 1_000_000, accuracy: 1)
    }

    func testStalledDownloadDecays() throws {
        var tracker = Self.steadyTracker(bytesPerSecond: 1_000_000, seconds: 3)
        tracker.record(totalBytes: 3_001_000, at: 4)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 700_000, accuracy: 1)
        for second in 5..<40 { tracker.record(totalBytes: 3_001_000, at: Double(second)) }
        XCTAssertLessThan(try XCTUnwrap(tracker.bytesPerSecond), DownloadProgressDetail.minimumSpeed)
    }

    func testLongGapRestartsTheBaselineInsteadOfAveragingItIn() throws {
        var tracker = Self.steadyTracker(bytesPerSecond: 1_000_000, seconds: 3)
        // Suspended for ten minutes while the background session carried on.
        tracker.record(totalBytes: 900_000_000, at: 603)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 1_000_000, accuracy: 1)
        tracker.record(totalBytes: 901_000_000, at: 604)
        XCTAssertEqual(try XCTUnwrap(tracker.bytesPerSecond), 1_000_000, accuracy: 1)
    }

    func testByteCountGoingBackwardsStartsOver() {
        var tracker = Self.steadyTracker(bytesPerSecond: 1_000_000, seconds: 3)
        tracker.record(totalBytes: 500, at: 4)
        XCTAssertNil(tracker.bytesPerSecond)
    }

    // MARK: - Time left

    func testTimeLeftComesFromTheBytesStillToComeAndTheSpeed() throws {
        let detail = DownloadProgressDetail.make(
            receivedBytes: 182_000_000, exactTotalBytes: -1, estimatedTotalBytes: 420_000_000, bytesPerSecond: 3_100_000
        )
        XCTAssertEqual(try XCTUnwrap(detail.secondsRemaining), 238_000_000 / 3_100_000, accuracy: 0.01)
    }

    func testTimeLeftIsNeverNegativeEvenPastTheEstimate() throws {
        for received in [Int64(420_000_000), 500_000_000, 4_200_000_000] {
            let detail = DownloadProgressDetail.make(
                receivedBytes: received, exactTotalBytes: -1, estimatedTotalBytes: 420_000_000, bytesPerSecond: 3_100_000
            )
            XCTAssertGreaterThan(try XCTUnwrap(detail.secondsRemaining), 0, "at \(received)")
        }
    }

    func testSpeedAndTimeLeftAreHiddenWithoutAUsableSpeed() {
        for speed in [nil, 0, 200, Double.nan] as [Double?] {
            let detail = DownloadProgressDetail.make(
                receivedBytes: 100, exactTotalBytes: 1_000, estimatedTotalBytes: nil, bytesPerSecond: speed
            )
            XCTAssertNil(detail.bytesPerSecond, "\(String(describing: speed))")
            XCTAssertNil(detail.secondsRemaining, "\(String(describing: speed))")
        }
    }

    func testTimeLeftIsHiddenWhenThereIsNoTotal() {
        let detail = DownloadProgressDetail.make(
            receivedBytes: 100, exactTotalBytes: -1, estimatedTotalBytes: nil, bytesPerSecond: 1_000_000
        )
        XCTAssertNotNil(detail.bytesPerSecond)
        XCTAssertNil(detail.secondsRemaining)
    }

    func testTimeLeftWording() {
        XCTAssertEqual(DownloadProgressText.timeLeft(seconds: 30), "less than a minute left")
        XCTAssertEqual(DownloadProgressText.timeLeft(seconds: 60), "about 1 min left")
        XCTAssertEqual(DownloadProgressText.timeLeft(seconds: 61), "about 2 min left")
        XCTAssertEqual(DownloadProgressText.timeLeft(seconds: 12 * 60), "about 12 min left")
        XCTAssertEqual(DownloadProgressText.timeLeft(seconds: 3_599), "about 1 hr left")
        XCTAssertEqual(DownloadProgressText.timeLeft(seconds: 80 * 60), "about 1 hr 20 min left")
        XCTAssertNil(DownloadProgressText.timeLeft(seconds: nil))
        XCTAssertNil(DownloadProgressText.timeLeft(seconds: -5))
        XCTAssertNil(DownloadProgressText.timeLeft(seconds: .infinity))
        XCTAssertNil(DownloadProgressText.timeLeft(seconds: 3 * 24 * 3_600))
    }

    // MARK: - Status line

    func testPercentRoundsDownAndNeverReachesOneHundred() {
        XCTAssertEqual(DownloadProgressText.percent(0), "0%")
        XCTAssertEqual(DownloadProgressText.percent(0.439), "43%")
        XCTAssertEqual(DownloadProgressText.percent(0.999), "99%")
        XCTAssertEqual(DownloadProgressText.percent(1.4), "99%")
        XCTAssertEqual(DownloadProgressText.percent(-1), "0%")
    }

    func testByteCountsAndSpeedsAreShort() {
        XCTAssertEqual(DownloadProgressText.byteCount(0), "0 KB")
        XCTAssertEqual(DownloadProgressText.byteCount(640_000), "640 KB")
        XCTAssertEqual(DownloadProgressText.byteCount(182_400_000), "182 MB")
        XCTAssertEqual(DownloadProgressText.byteCount(999_700_000), "1.0 GB")
        XCTAssertEqual(DownloadProgressText.byteCount(4_210_000_000), "4.2 GB")
        XCTAssertEqual(DownloadProgressText.speed(640_000), "640 KB/s")
        XCTAssertEqual(DownloadProgressText.speed(3_140_000), "3.1 MB/s")
        XCTAssertEqual(DownloadProgressText.speed(11_200_000), "11.2 MB/s")
    }

    func testEstimatedTotalIsMarkedAndExactIsNot() {
        let estimated = DownloadProgressDisplay.make(
            receivedBytes: 182_000_000, exactTotalBytes: -1, estimatedTotalBytes: 420_000_000
        )
        XCTAssertEqual(DownloadProgressText.bytes(estimated), "182 MB of ~420 MB")
        let exact = DownloadProgressDisplay.make(
            receivedBytes: 182_000_000, exactTotalBytes: 420_000_000, estimatedTotalBytes: nil
        )
        XCTAssertEqual(DownloadProgressText.bytes(exact), "182 MB of 420 MB")
    }

    func testStatusLinesDropTimeLeftFirstThenSpeedThenBytes() {
        let detail = DownloadProgressDetail.make(
            receivedBytes: 182_000_000, exactTotalBytes: -1, estimatedTotalBytes: 420_000_000, bytesPerSecond: 3_100_000
        )
        XCTAssertEqual(DownloadProgressText.statusLines(for: detail).map(\.text), [
            "43% · 182 MB of ~420 MB · 3.1 MB/s · about 2 min left",
            "43% · 182 MB of ~420 MB · 3.1 MB/s",
            "43% · 182 MB of ~420 MB",
            "43%",
        ])
    }

    func testStatusLinesBeforeThereIsASpeed() {
        let detail = DownloadProgressDetail.make(
            receivedBytes: 4_000_000, exactTotalBytes: 420_000_000, estimatedTotalBytes: nil, bytesPerSecond: nil
        )
        XCTAssertEqual(DownloadProgressText.statusLines(for: detail).map(\.text), ["0% · 4 MB of 420 MB", "0%"])
    }

    func testStatusLinesWithoutAnyTotal() {
        let detail = DownloadProgressDetail.make(
            receivedBytes: 182_000_000, exactTotalBytes: -1, estimatedTotalBytes: nil, bytesPerSecond: 3_100_000
        )
        XCTAssertEqual(DownloadProgressText.statusLines(for: detail).map(\.text), ["182 MB · 3.1 MB/s", "182 MB"])
    }

    func testAccessibilityLabelReadsTheSameInformation() {
        let estimated = DownloadProgressDetail.make(
            receivedBytes: 182_000_000, exactTotalBytes: -1, estimatedTotalBytes: 420_000_000, bytesPerSecond: 3_100_000
        )
        XCTAssertEqual(
            DownloadProgressText.accessibilityLabel(for: estimated),
            "43 percent, 182 MB of about 420 MB, 3.1 MB per second, about 2 min left"
        )
        let exact = DownloadProgressDetail.make(
            receivedBytes: 182_000_000, exactTotalBytes: 420_000_000, estimatedTotalBytes: nil, bytesPerSecond: nil
        )
        XCTAssertEqual(DownloadProgressText.accessibilityLabel(for: exact), "43 percent, 182 MB of 420 MB")
    }

    // MARK: - Row state

    func testWaitingPreparingAndQueuedKeepTheirOwnStates() {
        let moving = DownloadProgressDetail.make(
            receivedBytes: 182, exactTotalBytes: -1, estimatedTotalBytes: 420, bytesPerSecond: 3_100_000
        )
        let nothingYet = DownloadProgressDetail.make(
            receivedBytes: 0, exactTotalBytes: -1, estimatedTotalBytes: 420, bytesPerSecond: nil
        )

        XCTAssertEqual(
            DownloadRowStatus.resolve(waitReason: .cellular, isPreparing: false, detail: moving),
            .waiting(.cellular)
        )
        XCTAssertEqual(DownloadRowStatus.resolve(waitReason: nil, isPreparing: true, detail: moving), .preparing)
        XCTAssertEqual(DownloadRowStatus.resolve(waitReason: nil, isPreparing: false, detail: nil), .queued)
        XCTAssertEqual(DownloadRowStatus.resolve(waitReason: nil, isPreparing: false, detail: moving), .downloading(moving))
        // Started, but the server hasn't sent anything: "Preparing...", not 0%.
        XCTAssertEqual(DownloadRowStatus.resolve(waitReason: nil, isPreparing: false, detail: nothingYet), .preparing)
    }

    // MARK: - Persistence

    func testEstimateInputsSurviveInUserDefaults() throws {
        let suite = "DownloadProgressModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let input = DownloadEstimateInput(
            quality: DownloadQuality.low.rawValue,
            runTimeTicks: Self.fortyTwoMinutes,
            sourceBitrate: 2_000_000,
            sourceVideoBitrate: 1_800_000
        )
        DownloadEstimateStore.set(input, recordID: "server:a", defaults: defaults)
        DownloadEstimateStore.set(DownloadEstimateInput(quality: "high"), recordID: "server:b", defaults: defaults)

        XCTAssertEqual(DownloadEstimateStore.input(recordID: "server:a", defaults: defaults), input)
        XCTAssertNil(DownloadEstimateStore.input(recordID: "server:c", defaults: defaults))

        DownloadEstimateStore.forget(recordID: "server:a", defaults: defaults)
        XCTAssertNil(DownloadEstimateStore.input(recordID: "server:a", defaults: defaults))
        XCTAssertNotNil(DownloadEstimateStore.input(recordID: "server:b", defaults: defaults))

        DownloadEstimateStore.clearAll(defaults: defaults)
        XCTAssertTrue(DownloadEstimateStore.all(defaults: defaults).isEmpty)
    }

    // MARK: - Helpers

    /// A tracker that has seen `seconds` one-second samples at a steady rate,
    /// ending at 1_000 + rate x seconds bytes.
    private static func steadyTracker(bytesPerSecond: Int64, seconds: Int) -> DownloadSpeedTracker {
        var tracker = DownloadSpeedTracker()
        for second in 0...seconds {
            tracker.record(totalBytes: 1_000 + bytesPerSecond * Int64(second), at: Double(second))
        }
        return tracker
    }
}
