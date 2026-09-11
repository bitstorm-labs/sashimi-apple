import XCTest
@testable import Sashimi

final class PlayerTransitionStateTests: XCTestCase {
    func testEpisodeStateExposesOnlyAvailableBoundaries() {
        let current = makeItem(id: "current", type: .episode, index: 2)
        let previous = makeItem(id: "previous", type: .episode, index: 1)
        let next = makeItem(id: "next", type: .episode, index: 3)
        let state = PlayerTransitionState(
            currentItem: current,
            previousEpisode: previous,
            nextEpisode: next,
            lookupStatus: .available
        )

        XCTAssertTrue(state.usesEpisodeTransportControls(isEnabled: true))
        XCTAssertFalse(state.usesEpisodeTransportControls(isEnabled: false))
        XCTAssertTrue(state.isEpisodeNavigationAvailable)
        XCTAssertTrue(state.canPlayPrevious)
        XCTAssertTrue(state.canPlayNext)
    }

    func testEpisodeBoundariesDisableMissingControls() {
        let state = PlayerTransitionState(
            currentItem: makeItem(id: "final", type: .episode, index: 4),
            previousEpisode: nil,
            nextEpisode: nil,
            lookupStatus: .unavailable,
            endCard: .finalEpisode
        )

        XCTAssertFalse(state.canPlayPrevious)
        XCTAssertFalse(state.canPlayNext)
        XCTAssertEqual(state.endCard, .finalEpisode)
    }

    func testMoviesAndStandaloneVideosDoNotExposeEpisodeNavigation() {
        for type in [ItemType.movie, .video] {
            let state = PlayerTransitionState(
                currentItem: makeItem(id: type.rawValue, type: type, index: 1),
                previousEpisode: makeItem(id: "previous", type: .episode, index: 1),
                nextEpisode: makeItem(id: "next", type: .episode, index: 2),
                lookupStatus: .available
            )

            XCTAssertFalse(state.usesEpisodeTransportControls(isEnabled: true))
            XCTAssertFalse(state.usesEpisodeTransportControls(isEnabled: false))
            XCTAssertFalse(state.isEpisodeNavigationAvailable)
            XCTAssertFalse(state.canPlayPrevious)
            XCTAssertFalse(state.canPlayNext)
        }
    }

    func testOfflineEpisodesDoNotExposeServerNavigation() {
        let state = PlayerTransitionState(
            currentItem: makeItem(id: "offline", type: .episode, index: 1),
            previousEpisode: nil,
            nextEpisode: makeItem(id: "next", type: .episode, index: 2),
            lookupStatus: .notApplicable
        )

        XCTAssertFalse(state.usesEpisodeTransportControls(isEnabled: true))
        XCTAssertFalse(state.isEpisodeNavigationAvailable)
        XCTAssertFalse(state.canPlayNext)
    }

    func testLookupFailureHasDistinctUsableEndCardState() {
        let state = PlayerTransitionState(
            currentItem: makeItem(id: "current", type: .episode, index: 1),
            previousEpisode: nil,
            nextEpisode: nil,
            lookupStatus: .failed,
            endCard: .lookupFailed
        )

        XCTAssertEqual(state.lookupStatus, .failed)
        XCTAssertEqual(state.endCard, .lookupFailed)
        XCTAssertFalse(state.canPlayNext)
    }

    private func makeItem(id: String, type: ItemType, index: Int) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: id,
            type: type,
            seriesName: type == .episode ? "Series" : nil,
            seriesId: type == .episode ? "series" : nil,
            seasonId: type == .episode ? "season" : nil,
            parentId: nil,
            indexNumber: index,
            parentIndexNumber: type == .episode ? 1 : nil,
            overview: nil,
            runTimeTicks: nil,
            userData: nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
            libraryName: nil,
            productionYear: nil,
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
