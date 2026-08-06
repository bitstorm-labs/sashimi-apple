import XCTest
@testable import Sashimi

final class SearchResultGroupingTests: XCTestCase {
    private func makeItem(id: String, type: ItemType) -> BaseItemDto {
        BaseItemDto(
            id: id, name: id, type: type,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    func testMoviesComeBeforeShows() {
        let items = [
            makeItem(id: "s1", type: .series),
            makeItem(id: "m1", type: .movie),
            makeItem(id: "s2", type: .series),
            makeItem(id: "m2", type: .movie)
        ]
        let groups = SearchResultGrouping.groups(from: items)
        XCTAssertEqual(groups.map(\.title), ["Movies", "TV Shows"])
        XCTAssertEqual(groups[0].items.map(\.id), ["m1", "m2"])
        XCTAssertEqual(groups[1].items.map(\.id), ["s1", "s2"])
    }

    func testEmptySectionsAreDropped() {
        let groups = SearchResultGrouping.groups(from: [
            makeItem(id: "m1", type: .movie),
            makeItem(id: "m2", type: .movie)
        ])
        XCTAssertEqual(groups.map(\.title), ["Movies"])
    }

    func testServerOrderIsPreservedWithinASection() {
        let items = [
            makeItem(id: "m3", type: .movie),
            makeItem(id: "m1", type: .movie),
            makeItem(id: "m2", type: .movie)
        ]
        let groups = SearchResultGrouping.groups(from: items)
        XCTAssertEqual(groups.first?.items.map(\.id), ["m3", "m1", "m2"])
    }

    func testUnexpectedTypesCollectIntoOther() {
        // Nothing the server returns should be silently dropped.
        let groups = SearchResultGrouping.groups(from: [
            makeItem(id: "m1", type: .movie),
            makeItem(id: "e1", type: .episode),
            makeItem(id: "v1", type: .video)
        ])
        XCTAssertEqual(groups.map(\.title), ["Movies", "Other"])
        XCTAssertEqual(groups.last?.items.map(\.id), ["e1", "v1"])
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(SearchResultGrouping.groups(from: []).isEmpty)
    }
}
