import XCTest
@testable import Sashimi

/// #586: a remote iPad on a slow link was handed 7-10 Mbps streams with no
/// tier below 480p @ 4 Mbps, and stall recovery rebuilt them at the same
/// bitrate, so they stalled and restarted over and over.
final class LowBandwidthPlaybackTests: XCTestCase {
    // MARK: - Tiers

    func testLowBandwidthTiersExist() {
        XCTAssertEqual(QualityOption.quality720pLow.maxBitrate, 2_000_000)
        XCTAssertEqual(QualityOption.quality720pLow.maxWidth, 1280)
        XCTAssertEqual(QualityOption.quality480pLow.maxBitrate, 1_000_000)
        XCTAssertEqual(QualityOption.quality480pLow.maxWidth, 854)
        XCTAssertEqual(QualityOption.quality360p.maxBitrate, 720_000)
        XCTAssertEqual(QualityOption.quality360p.maxWidth, 640)
    }

    func testMenuSectionsKeepTheOriginalTiersFirst() {
        XCTAssertEqual(QualityOption.standardTiers, [.auto, .quality1080p, .quality720p, .quality480p])
        XCTAssertEqual(QualityOption.lowBandwidthTiers, [.quality720pLow, .quality480pLow, .quality360p])
    }

    func testMenuTitlesDistinguishTiersSharingAResolution() {
        XCTAssertEqual(QualityOption.auto.menuTitle, "Auto")
        XCTAssertEqual(QualityOption.quality720p.menuTitle, "720p · 8 Mbps")
        XCTAssertEqual(QualityOption.quality720pLow.menuTitle, "720p · 2 Mbps")
        XCTAssertEqual(QualityOption.quality360p.menuTitle, "360p · 720 kbps")
        XCTAssertEqual(Set(QualityOption.allCases.map(\.menuTitle)).count, QualityOption.allCases.count)
    }

    func testOriginalRawValuesAreStable() {
        XCTAssertEqual(QualityOption.allCases.prefix(4).map(\.rawValue), ["auto", "1080", "720", "480"])
    }

    func testBitrateLabel() {
        XCTAssertEqual(PlaybackSelection.bitrateLabel(20_000_000), "20 Mbps")
        XCTAssertEqual(PlaybackSelection.bitrateLabel(9_500_000), "9.5 Mbps")
        XCTAssertEqual(PlaybackSelection.bitrateLabel(720_000), "720 kbps")
    }

    // MARK: - Step-down

    func testStepDownHalvesToTheNextTierWithItsWidth() {
        XCTAssertEqual(QualityOption.steppedDown(fromBitrate: 20_000_000), .quality720p)
        XCTAssertEqual(QualityOption.steppedDown(fromBitrate: 8_000_000), .quality480p)
        XCTAssertEqual(QualityOption.steppedDown(fromBitrate: 4_000_000), .quality720pLow)
        XCTAssertEqual(QualityOption.steppedDown(fromBitrate: 2_000_000), .quality480pLow)
        XCTAssertEqual(QualityOption.steppedDown(fromBitrate: 1_000_000), .quality360p)
    }

    func testLiveAutoStreamStepsToA4MbpsTier() {
        // The observed 9.5 Mbps Auto stream.
        XCTAssertEqual(QualityOption.steppedDown(fromBitrate: 9_500_000), .quality480p)
    }

    func testStepDownStopsAtTheFloor() {
        XCTAssertNil(QualityOption.steppedDown(fromBitrate: 720_000))
        XCTAssertNil(QualityOption.steppedDown(fromBitrate: 500_000))
    }

    func testRepeatedStepDownsTerminate() {
        var bitrate = 100_000_000
        var steps = 0
        while let lower = QualityOption.steppedDown(fromBitrate: bitrate), let next = lower.maxBitrate {
            XCTAssertLessThan(next, bitrate)
            bitrate = next
            steps += 1
        }
        XCTAssertEqual(bitrate, QualityOption.floorBitrate)
        XCTAssertLessThanOrEqual(steps, QualityOption.allCases.count)
    }

    // MARK: - Recovery plan

    private typealias Plan = PlaybackRecoveryPlan

    func testSlowLinkStepsDownImmediately() {
        // Segments arriving at 6 Mbps for a 9.5 Mbps stream.
        let throughput = Plan.Throughput(observedBitrate: 6_000_000, indicatedBitrate: 9_500_000)
        XCTAssertEqual(
            Plan.decide(isStall: true, rebuildAttempts: 0, currentBitrate: 9_500_000, throughput: throughput),
            .stepDown(to: .quality480p)
        )
    }

    func testFastLinkFreezeStillGetsTheSameQualityRebuild() {
        // jellyfin#16070 on a LAN: throughput is many times the stream's, the
        // session is what's wedged. Same-quality rebuild, copy allowed.
        let throughput = Plan.Throughput(observedBitrate: 300_000_000, indicatedBitrate: 20_000_000)
        XCTAssertEqual(
            Plan.decide(isStall: true, rebuildAttempts: 0, currentBitrate: 20_000_000, throughput: throughput),
            .rebuild(allowVideoStreamCopy: true)
        )
    }

    func testSecondStallWithoutEvidenceStepsDown() {
        XCTAssertEqual(
            Plan.decide(isStall: true, rebuildAttempts: 1, currentBitrate: 4_000_000, throughput: nil),
            .stepDown(to: .quality720pLow)
        )
    }

    func testErrorsKeepTheLegacyEscalation() {
        XCTAssertEqual(
            Plan.decide(isStall: false, rebuildAttempts: 0, currentBitrate: 8_000_000, throughput: nil),
            .rebuild(allowVideoStreamCopy: true)
        )
        XCTAssertEqual(
            Plan.decide(isStall: false, rebuildAttempts: 1, currentBitrate: 8_000_000, throughput: nil),
            .rebuild(allowVideoStreamCopy: false)
        )
        XCTAssertEqual(
            Plan.decide(isStall: false, rebuildAttempts: 2, currentBitrate: 8_000_000, throughput: nil),
            .giveUp
        )
    }

    func testAtTheFloorRecoveryEnds() {
        XCTAssertEqual(
            Plan.decide(isStall: true, rebuildAttempts: 2, currentBitrate: 720_000, throughput: nil),
            .giveUp
        )
    }

    func testMissingAccessLogIsNotBandwidthEvidence() {
        XCTAssertFalse(Plan.isBandwidthLimited(nil))
        XCTAssertFalse(Plan.isBandwidthLimited(.init(observedBitrate: 0, indicatedBitrate: 4_000_000)))
        XCTAssertFalse(Plan.isBandwidthLimited(.init(observedBitrate: 4_000_000, indicatedBitrate: -1)))
    }

    // MARK: - Recovery in the view model

    @MainActor
    func testRepeatedStallsStepTheStreamDown() async {
        let item = BaseItemDto(
            id: "episode-1", name: "Test", type: .episode,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
        var requests: [(bitrate: Int?, width: Int?, copy: Bool)] = []
        let viewModel = PlayerViewModel(client: JellyfinClient(), recoverySetup: { _, bitrate, width, copy in
            requests.append((bitrate, width, copy))
        })
        viewModel.currentItem = item
        viewModel.selectedQuality = .quality480p

        let stall = PlayerViewModel.stallRecoveryReason
        for _ in 0..<3 {
            await viewModel.attemptPlaybackRecovery(reason: stall, itemID: item.id, attempt: viewModel.playbackAttempt)
        }

        // First: the seek-freeze rebuild at the same quality. Then down a tier
        // each time, with the tier's width, never the same bitrate again.
        XCTAssertEqual(requests.map(\.bitrate), [4_000_000, 2_000_000, 1_000_000])
        XCTAssertEqual(requests.map(\.width), [854, 1280, 854])
        XCTAssertEqual(requests.map(\.copy), [true, false, false])
        XCTAssertEqual(viewModel.selectedQuality, .quality480pLow)
        XCTAssertEqual(viewModel.qualityStatusLabel, "480p · 1 Mbps")
        XCTAssertNotNil(viewModel.playbackNotice)
        viewModel.clearPlaybackNotice()
    }
}
