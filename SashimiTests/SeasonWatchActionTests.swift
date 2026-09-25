import XCTest
@testable import Sashimi

/// Deciding between "Mark Season Watched" and "Mark Season Unwatched", and
/// sending the season id (not episode ids) to the right endpoint.
final class SeasonWatchActionTests: XCTestCase {
    private func item(_ id: String, type: ItemType, played: Bool?) -> BaseItemDto {
        let userData = played.map {
            UserItemDataDto(
                playbackPositionTicks: nil, playCount: nil, isFavorite: nil,
                played: $0, lastPlayedDate: nil, unplayedItemCount: nil
            )
        }
        return BaseItemDto(
            id: id, name: id, type: type,
            seriesName: nil, seriesId: "series", seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: userData, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    private func episodes(_ played: [Bool?]) -> [BaseItemDto] {
        played.enumerated().map { item("ep\($0.offset)", type: .episode, played: $0.element) }
    }

    // MARK: - Watched vs Unwatched

    func testAllEpisodesPlayedOffersUnwatched() {
        let season = item("s1", type: .season, played: false)
        let action = SeasonWatchAction.resolve(season: season, loadedEpisodes: episodes([true, true, true]))
        XCTAssertEqual(action, .markUnwatched)
        XCTAssertEqual(action.title, "Mark Season Unwatched")
    }

    func testAnyUnplayedEpisodeOffersWatched() {
        let season = item("s1", type: .season, played: true)
        let action = SeasonWatchAction.resolve(season: season, loadedEpisodes: episodes([true, false, true]))
        XCTAssertEqual(action, .markWatched)
        XCTAssertEqual(action.title, "Mark Season Watched")
    }

    func testEpisodeWithoutUserDataCountsAsUnplayed() {
        let season = item("s1", type: .season, played: nil)
        XCTAssertEqual(
            SeasonWatchAction.resolve(season: season, loadedEpisodes: episodes([true, nil])),
            .markWatched
        )
    }

    func testFallsBackToSeasonPlayedFlagWithoutEpisodes() {
        let watched = item("s1", type: .season, played: true)
        let unwatched = item("s2", type: .season, played: false)
        XCTAssertEqual(SeasonWatchAction.resolve(season: watched, loadedEpisodes: nil), .markUnwatched)
        XCTAssertEqual(SeasonWatchAction.resolve(season: watched, loadedEpisodes: []), .markUnwatched)
        XCTAssertEqual(SeasonWatchAction.resolve(season: unwatched, loadedEpisodes: nil), .markWatched)
        XCTAssertEqual(
            SeasonWatchAction.resolve(season: item("s3", type: .season, played: nil), loadedEpisodes: nil),
            .markWatched
        )
    }

    // MARK: - Availability

    func testOfflineSyntheticSeasonsAndNoConnectionCannotApply() {
        let real = item("abc123", type: .season, played: false)
        let synthetic = item("offline-season-0", type: .season, played: nil)
        XCTAssertTrue(SeasonWatchAction.canApply(to: real, isConnected: true))
        XCTAssertFalse(SeasonWatchAction.canApply(to: real, isConnected: false))
        XCTAssertFalse(SeasonWatchAction.canApply(to: synthetic, isConnected: true))
    }

    // MARK: - Server call

    func testMarkWatchedPostsTheSeasonId() async throws {
        let client = RecordingClient()
        try await SeasonWatchAction.markWatched.apply(seasonId: "season-0", using: client)
        let calls = await client.calls
        XCTAssertEqual(calls, ["played:season-0"])
    }

    func testMarkUnwatchedDeletesTheSeasonId() async throws {
        let client = RecordingClient()
        try await SeasonWatchAction.markUnwatched.apply(seasonId: "season-2", using: client)
        let calls = await client.calls
        XCTAssertEqual(calls, ["unplayed:season-2"])
    }

    func testServerFailurePropagates() async {
        let client = RecordingClient(failing: true)
        do {
            try await SeasonWatchAction.markWatched.apply(seasonId: "s", using: client)
            XCTFail("expected the server error to reach the caller")
        } catch {
            XCTAssertEqual(error as? RecordingClient.Failure, .boom)
        }
    }
}

private actor RecordingClient: PlayedStateMarking {
    enum Failure: Error { case boom }

    private(set) var calls: [String] = []
    private let failing: Bool

    init(failing: Bool = false) { self.failing = failing }

    func markPlayed(itemId: String) async throws {
        if failing { throw Failure.boom }
        calls.append("played:\(itemId)")
    }

    func markUnplayed(itemId: String) async throws {
        if failing { throw Failure.boom }
        calls.append("unplayed:\(itemId)")
    }
}
