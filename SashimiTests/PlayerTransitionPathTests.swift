import XCTest
@testable import Sashimi

@MainActor
final class PlayerTransitionPathTests: XCTestCase {
    func testNavigationUsesOrderedNonAdjacentSeasonsForBothDirections() async {
        let current = makeItem(
            id: "season-3-episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-3",
            seasonNumber: 3,
            episodeNumber: 1
        )
        let previous = makeItem(
            id: "season-1-episode-2",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 2
        )
        let next = makeItem(
            id: "season-5-episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-5",
            seasonNumber: 5,
            episodeNumber: 1
        )
        let client = FakePlayerEpisodeNavigationClient(
            itemsByParent: [
                "season-3": [current],
                "series": [
                    makeItem(id: "season-1", type: .season, seriesId: "series", seasonNumber: 1),
                    makeItem(id: "season-3", type: .season, seriesId: "series", seasonNumber: 3),
                    makeItem(id: "season-5", type: .season, seriesId: "series", seasonNumber: 5),
                ],
                "season-1": [previous],
                "season-5": [next],
            ]
        )
        let viewModel = PlayerViewModel(navigationClient: client)
        viewModel.currentItem = current

        await viewModel.refreshEpisodeNavigation()

        XCTAssertEqual(viewModel.transitionState.previousEpisode?.id, previous.id)
        XCTAssertEqual(viewModel.transitionState.nextEpisode?.id, next.id)
        XCTAssertTrue(viewModel.transitionState.canPlayPrevious)
        XCTAssertTrue(viewModel.transitionState.canPlayNext)
    }

    func testNavigationFailureKeepsFailureDistinctFromFinalEpisode() async {
        let current = makeItem(
            id: "episode-1",
            type: .episode,
            seriesId: "series",
            seasonId: "season-1",
            seasonNumber: 1,
            episodeNumber: 1
        )
        let client = FakePlayerEpisodeNavigationClient(error: FakeNavigationError.failed)
        let viewModel = PlayerViewModel(navigationClient: client)
        viewModel.currentItem = current

        await viewModel.refreshEpisodeNavigation()

        XCTAssertEqual(viewModel.transitionState.lookupStatus, .failed)
        XCTAssertNil(viewModel.transitionState.endCard)
    }

    private func makeItem(
        id: String,
        type: ItemType,
        seriesId: String? = nil,
        seasonId: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: id,
            type: type,
            seriesName: seriesId == nil ? nil : "Series",
            seriesId: seriesId,
            seasonId: seasonId,
            parentId: seasonId,
            indexNumber: episodeNumber,
            parentIndexNumber: seasonNumber,
            overview: nil,
            runTimeTicks: nil,
            userData: nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
            libraryName: "Shows",
            productionYear: 2026,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            taglines: nil,
            people: nil,
            criticRating: nil,
            premiereDate: nil,
            chapters: nil,
            path: nil,
            remoteTrailers: nil,
            localTrailerCount: nil,
            mediaStreams: nil
        )
    }
}

private actor FakePlayerEpisodeNavigationClient: PlayerEpisodeNavigationClient {
    private let itemsByParent: [String: [BaseItemDto]]
    private let error: Error?

    init(
        itemsByParent: [String: [BaseItemDto]] = [:],
        error: Error? = nil
    ) {
        self.itemsByParent = itemsByParent
        self.error = error
    }

    func getPlayerItems(
        parentId: String,
        includeTypes: [ItemType],
        sortBy: String,
        limit: Int
    ) async throws -> ItemsResponse {
        if let error { throw error }
        let items = itemsByParent[parentId] ?? []
        return ItemsResponse(items: items, totalRecordCount: items.count)
    }
}

private enum FakeNavigationError: Error {
    case failed
}
