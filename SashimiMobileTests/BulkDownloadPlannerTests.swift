import XCTest
@testable import SashimiMobile

final class BulkDownloadPlannerTests: XCTestCase {
    // MARK: - Selection

    func testSeriesUnwatchedSkipsWatchedEpisodesAndSpecials() {
        let episodes = [
            Self.episode("s0e1", season: 0, played: false),
            Self.episode("s1e1", season: 1, played: true),
            Self.episode("s1e2", season: 1, played: false),
            Self.episode("s2e1", season: 2, played: nil),
            Self.episode("s2e2", season: 2, played: true),
        ]

        let ids = BulkDownloadPlanner.select(.seriesUnwatched, from: episodes).map(\.id)

        XCTAssertEqual(ids, ["s1e2", "s2e1"])
    }

    func testSeriesSelectsEveryEpisodeIncludingSpecialsAndWatched() {
        let episodes = [
            Self.episode("s0e1", season: 0, played: true),
            Self.episode("s1e1", season: 1, played: true),
            Self.episode("s1e2", season: 1, played: false),
        ]

        XCTAssertEqual(BulkDownloadPlanner.select(.series, from: episodes).map(\.id), ["s0e1", "s1e1", "s1e2"])
    }

    func testSeasonScopesSelectAllOrUnwatchedInTheSeason() {
        let episodes = [
            Self.episode("e1", season: 3, played: true),
            Self.episode("e2", season: 3, played: false),
            Self.episode("e3", season: 3, played: false),
        ]

        XCTAssertEqual(BulkDownloadPlanner.select(.season, from: episodes).map(\.id), ["e1", "e2", "e3"])
        XCTAssertEqual(BulkDownloadPlanner.select(.seasonUnwatched, from: episodes).map(\.id), ["e2", "e3"])
        XCTAssertEqual(BulkDownloadPlanner.select(.nextUnwatched(1), from: episodes).map(\.id), ["e2"])
    }

    func testUnwatchedInASpecialsSeasonKeepsTheSpecials() {
        // "Unwatched in Season" on Specials must not come back empty just
        // because the series-wide rule excludes season 0.
        let specials = [Self.episode("sp1", season: 0, played: false)]

        XCTAssertEqual(BulkDownloadPlanner.select(.seasonUnwatched, from: specials).map(\.id), ["sp1"])
    }

    // MARK: - Skipping existing downloads

    func testPendingSkipsDownloadedQueuedAndDownloadingButRequeuesFailed() {
        let episodes = ["done", "queued", "preparing", "downloading", "failed", "paused", "new", "new"]
            .map { Self.episode($0, season: 1, played: false) }
        let statuses: [String: DownloadStatus] = [
            "done": .completed, "queued": .queued, "preparing": .preparing,
            "downloading": .downloading, "failed": .failed,
            // A legacy stored "paused" record reads as failed (#608).
            "paused": DownloadStatus.fromStored("paused"),
        ]

        let ids = BulkDownloadPlanner.pending(episodes) { statuses[$0] }.map(\.id)

        XCTAssertEqual(ids, ["failed", "paused", "new"])
    }

    // MARK: - Confirmation

    func testConfirmationStartsAboveTenEpisodes() {
        XCTAssertEqual(BulkDownloadPlanner.confirmationThreshold, 10)
        XCTAssertFalse(BulkDownloadPlanner.needsConfirmation(count: 1))
        XCTAssertFalse(BulkDownloadPlanner.needsConfirmation(count: 10))
        XCTAssertTrue(BulkDownloadPlanner.needsConfirmation(count: 11))
        XCTAssertTrue(BulkDownloadPlanner.needsConfirmation(count: 24))
    }

    func testEstimatedBytesUsesRuntimeAndQualityBitrate() {
        // 2 x 45 min at Low (4 Mbps): 5400 s x 4_000_000 / 8 = 2.7 GB.
        let fortyFiveMinutes: Int64 = 45 * 60 * 10_000_000
        let episodes = [
            Self.episode("a", season: 1, played: false, runTimeTicks: fortyFiveMinutes),
            Self.episode("b", season: 1, played: false, runTimeTicks: fortyFiveMinutes),
            Self.episode("c", season: 1, played: false, runTimeTicks: nil),
        ]

        XCTAssertEqual(BulkDownloadPlanner.estimatedBytes(for: episodes, quality: .low), 2_700_000_000)
        XCTAssertNil(BulkDownloadPlanner.estimatedBytes(for: episodes, quality: .original))
        XCTAssertNil(BulkDownloadPlanner.estimatedBytes(for: [episodes[2]], quality: .high))
    }

    func testConfirmationTitleShowsCountAndSizeOrJustCount() {
        let sized = BulkDownloadPlanner.confirmationTitle(count: 24, estimatedBytes: 18_000_000_000)
        XCTAssertTrue(sized.hasPrefix("Download 24 episodes (~18"), sized)
        XCTAssertTrue(sized.hasSuffix("GB)?"), sized)
        XCTAssertEqual(BulkDownloadPlanner.confirmationTitle(count: 24, estimatedBytes: nil), "Download 24 episodes?")
    }

    func testActionTitlesMatchTheSharedSpec() {
        XCTAssertEqual(BulkDownloadScope.seriesUnwatched.title, "Download Unwatched")
        XCTAssertEqual(BulkDownloadScope.series.title, "Download Series")
        XCTAssertEqual(BulkDownloadScope.season.title, "Download Season")
        XCTAssertEqual(BulkDownloadScope.seasonUnwatched.title, "Download Unwatched in Season")
    }

    // MARK: - Helpers

    private static func episode(
        _ id: String,
        season: Int?,
        played: Bool?,
        runTimeTicks: Int64? = nil
    ) -> BaseItemDto {
        BaseItemDto(
            id: id, name: id, type: .episode,
            seriesName: "Show", seriesId: "series", seasonId: nil, parentId: nil,
            indexNumber: 1, parentIndexNumber: season, overview: nil,
            runTimeTicks: runTimeTicks,
            userData: UserItemDataDto(
                playbackPositionTicks: nil, playCount: nil, isFavorite: nil,
                played: played, lastPlayedDate: nil, unplayedItemCount: nil
            ),
            imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil,
            productionYear: nil, communityRating: nil, officialRating: nil,
            genres: nil, taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }
}
