import XCTest
@testable import SashimiMobile

/// The episode download menu's selections (#744), the same cases as
/// sashimi-android's EpisodeDownloadPlannerTest.
final class EpisodeDownloadPlannerTests: XCTestCase {
    private static func ep(_ id: String, season: Int, number: Int = 1, played: Bool = false, name: String? = nil) -> BaseItemDto {
        let json: [String: Any] = [
            "Id": id, "Name": name ?? id, "Type": "Episode", "SeriesId": "series",
            "SeasonId": "season\(season)", "ParentIndexNumber": season, "IndexNumber": number,
            "UserData": ["Played": played]
        ]
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(BaseItemDto.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Airing order as /Shows/{id}/Episodes returns it; a special filed within season 2.
    private let series = [
        ep("sp1", season: 0),
        ep("s1e1", season: 1, number: 1, played: true),
        ep("s1e2", season: 1, number: 2),
        ep("s1e3", season: 1, number: 3),
        ep("s2e1", season: 2, number: 1),
        ep("sp2", season: 0, number: 2),
        ep("s2e2", season: 2, number: 2, played: true),
        ep("s2e3", season: 2, number: 3)
    ]

    private func next(_ tapped: String, _ count: Int, status: [String: DownloadStatus] = [:]) -> [String] {
        let episode = series.first { $0.id == tapped }!
        return EpisodeDownloadPlanner.select(.thisAndNext(count), for: episode, seriesEpisodes: series) { status[$0] }
            .map(\.id)
    }

    func testThisAndTheNextCrossesIntoTheNextSeason() {
        XCTAssertEqual(next("s1e2", 2), ["s1e2", "s1e3", "s2e1"])
    }

    func testSpecialsAreNeverAmongTheNextN() {
        XCTAssertEqual(next("s2e1", 2), ["s2e1", "s2e2", "s2e3"])
    }

    func testATappedSpecialIsItselfDownloaded() {
        XCTAssertEqual(next("sp1", 1), ["sp1", "s1e1"])
    }

    func testDownloadedOrQueuedInTheWindowAreSkippedNotReplacedAndFailedAreRetried() {
        let status: [String: DownloadStatus] = ["s1e3": .completed, "s2e1": .queued, "s2e2": .failed]
        XCTAssertEqual(next("s1e2", 3, status: status), ["s1e2", "s2e2"])
    }

    func testTheWindowStopsAtTheEndOfTheSeries() {
        XCTAssertEqual(next("s2e2", 10), ["s2e2", "s2e3"])
    }

    func testZeroMeansJustThisEpisode() {
        XCTAssertEqual(next("s1e2", 0), ["s1e2"])
    }

    func testUnwatchedInSeasonUsesTheTappedEpisodesSeasonOnly() {
        let tapped = series.first { $0.id == "s2e1" }!
        let ids = EpisodeDownloadPlanner.select(.unwatchedInSeason, for: tapped, seriesEpisodes: series) { _ in nil }.map(\.id)
        XCTAssertEqual(ids, ["s2e1", "s2e3"])
    }

    func testUnwatchedInSeriesSkipsSpecialsPlayedAndDownloaded() {
        let tapped = series[2]
        let ids = EpisodeDownloadPlanner.select(.unwatchedInSeries, for: tapped, seriesEpisodes: series) {
            $0 == "s1e3" ? .downloading : nil
        }.map(\.id)
        XCTAssertEqual(ids, ["s1e2", "s2e1", "s2e3"])
    }

    func testLabelsMatchTheApprovedMockup() {
        let tapped = Self.ep("x", season: 2, number: 3, name: "Shooter Ready")
        XCTAssertEqual(EpisodeDownloadPlanner.menuTitle(tapped), "S2 E3 \u{00B7} Shooter Ready")
        XCTAssertEqual(EpisodeDownloadPlanner.seasonTitle(tapped), "Unwatched in Season 2")
        XCTAssertEqual(EpisodeDownloadPlanner.seasonLabel(Self.ep("y", season: 0)), "Specials")
        XCTAssertEqual(EpisodeDownloadPlanner.nextCounts, [1, 3, 5, 10])
        XCTAssertEqual(EpisodeDownloadPlanner.nextCountTitle(1), "Next episode")
        XCTAssertEqual(EpisodeDownloadPlanner.nextCountTitle(5), "Next 5 episodes")
    }
}
