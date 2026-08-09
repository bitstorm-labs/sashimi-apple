import XCTest
@testable import Sashimi

final class PersonFilmographyTests: XCTestCase {
    func testPersonInfoDecodingAndDisplayRole() throws {
        let json = """
        {
            "Id": "person-1",
            "Name": "Taylor Example",
            "Type": "Director",
            "PrimaryImageTag": "image-tag"
        }
        """.data(using: .utf8)!

        let person = try JSONDecoder().decode(PersonInfo.self, from: json)

        XCTAssertEqual(person.id, "person-1")
        XCTAssertEqual(person.name, "Taylor Example")
        XCTAssertEqual(person.displayRole, "Director")
        XCTAssertEqual(person.primaryImageTag, "image-tag")
    }

    func testPeopleSortActorsFirstAndPreservesCrew() {
        let people = [
            PersonInfo(id: "crew", name: "A Crew Member", role: nil, type: "Writer", primaryImageTag: nil),
            PersonInfo(id: "actor", name: "Z Actor", role: "Hero", type: "Actor", primaryImageTag: nil),
            PersonInfo(id: "actor-2", name: "A Actor", role: nil, type: "Actor", primaryImageTag: nil)
        ]

        let sorted = PersonInfo.sortedForDisplay(people)

        XCTAssertEqual(sorted.map(\.id), ["actor-2", "actor", "crew"])
        XCTAssertEqual(sorted[1].displayRole, "Hero")
    }

    @MainActor
    func testVisibleMediaKeepsMoviesAndSeriesOnlyAndDeduplicates() {
        let media = [
            makeItem(id: "movie-1", type: .movie),
            makeItem(id: "series-1", type: .series),
            makeItem(id: "episode-1", type: .episode),
            makeItem(id: "movie-1", type: .movie),
            makeItem(id: "source-item", type: .movie)
        ]

        let visible = PersonFilmographyViewModel.visibleMedia(
            from: media,
            excludingItemID: "source-item"
        )

        XCTAssertEqual(visible.map(\.id), ["movie-1", "series-1"])
    }

    @MainActor
    func testOfflineFilmographyDoesNotShowStaleItems() async {
        let viewModel = PersonFilmographyViewModel()

        await viewModel.load(personID: "person-1", isOffline: true)

        let state = viewModel.state
        let items = viewModel.items
        XCTAssertEqual(state, .unavailable)
        XCTAssertTrue(items.isEmpty)
    }

    private func makeItem(id: String, type: ItemType) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: id,
            type: type,
            seriesName: nil,
            seriesId: nil,
            seasonId: nil,
            parentId: nil,
            indexNumber: nil,
            parentIndexNumber: nil,
            overview: nil,
            runTimeTicks: nil,
            userData: nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
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
