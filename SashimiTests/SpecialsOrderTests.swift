import XCTest
@testable import Sashimi

/// Specials (Season 0) play after the regular seasons (roku#134 parity).
final class SpecialsOrderTests: XCTestCase {
    private func item(_ id: String, type: ItemType, index: Int?, parentIndex: Int? = nil) -> BaseItemDto {
        BaseItemDto(
            id: id, name: id, type: type,
            seriesName: nil, seriesId: "series", seasonId: nil, parentId: nil,
            indexNumber: index, parentIndexNumber: parentIndex, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    func testSpecialsSeasonMovesToTheEnd() {
        let seasons = [
            item("specials", type: .season, index: 0),
            item("s1", type: .season, index: 1),
            item("s2", type: .season, index: 2)
        ]
        XCTAssertEqual(seasons.specialsLast.map(\.id), ["s1", "s2", "specials"])
    }

    func testOnlySeasonZeroEpisodesAreSpecials() {
        XCTAssertTrue(item("e", type: .episode, index: 9, parentIndex: 0).isSpecial)
        XCTAssertFalse(item("e", type: .episode, index: 1, parentIndex: 1).isSpecial)
        XCTAssertFalse(item("m", type: .movie, index: nil, parentIndex: 0).isSpecial)
    }
}
