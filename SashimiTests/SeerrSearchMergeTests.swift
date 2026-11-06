import XCTest
@testable import Sashimi

/// Search's "Not in your library" row lists only what isn't already on the
/// server: the library row owns everything that is.
final class SeerrSearchMergeTests: XCTestCase {
    private func libraryItem(_ name: String, type: ItemType, tmdb: String?, year: Int? = nil) throws -> BaseItemDto {
        var fields = ["\"Id\":\"\(UUID().uuidString)\"", "\"Name\":\"\(name)\"", "\"Type\":\"\(type.rawValue)\""]
        if let tmdb { fields.append("\"ProviderIds\":{\"Tmdb\":\"\(tmdb)\",\"Imdb\":\"tt1\"}") }
        if let year { fields.append("\"ProductionYear\":\(year)") }
        return try JSONDecoder().decode(BaseItemDto.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func result(_ id: Int, _ kind: SeerrMediaKind, _ title: String, date: String? = nil, status: Int? = nil) -> SeerrSearchResult {
        SeerrSearchResult(tmdbId: id, kind: kind, title: title, date: date, mediaInfo: status.map { SeerrMediaInfo(status: $0) })
    }

    func testLibraryItemsReadTheirTmdbId() throws {
        XCTAssertEqual(try libraryItem("Dune", type: .movie, tmdb: "438631").tmdbId, 438631)
        XCTAssertNil(try libraryItem("Home video", type: .movie, tmdb: nil).tmdbId)
    }

    func testDropsWhatTheServerHasAndWhatTheLibraryRowAlreadyShows() throws {
        let library = [
            try libraryItem("Dune", type: .movie, tmdb: "438631"),
            try libraryItem("Dune: Part Two", type: .movie, tmdb: "693134")
        ]
        let results = [
            result(438631, .movie, "Dune"),
            result(693134, .movie, "Dune: Part Two", status: 5),
            result(90228, .tv, "Dune: Prophecy"),
            result(841, .movie, "Dune", date: "1984-12-14", status: 2),
            result(1, .movie, "Already on Plex", status: 5)
        ]

        let row = SeerrSearchMerge.requestable(results, library: library)

        XCTAssertEqual(row.map(\.title), ["Dune: Prophecy", "Dune"])
        XCTAssertEqual(row.last?.year, 1984)
    }

    func testAMovieAndAShowWithTheSameTmdbNumberAreDifferentTitles() throws {
        let library = [try libraryItem("Some Movie", type: .movie, tmdb: "100")]
        let row = SeerrSearchMerge.requestable([result(100, .tv, "Some Show")], library: library)
        XCTAssertEqual(row.map(\.title), ["Some Show"])
    }

    func testLibraryItemsWithoutProviderIdsMatchOnTitleAndYear() throws {
        let library = [try libraryItem("Dune", type: .movie, tmdb: nil, year: 2021)]
        let row = SeerrSearchMerge.requestable(
            [result(438631, .movie, "Dune", date: "2021-09-15"), result(841, .movie, "Dune", date: "1984-12-14")],
            library: library
        )
        XCTAssertEqual(row.map(\.year), [1984])
    }

    func testDuplicatesFromSeerrAppearOnce() {
        let row = SeerrSearchMerge.requestable([result(5, .movie, "A"), result(5, .movie, "A")], library: [])
        XCTAssertEqual(row.count, 1)
    }

    func testLibraryMatchFindsTheTitleByTmdbIdAndKind() throws {
        let show = try libraryItem("Dune: Prophecy", type: .series, tmdb: "90228")
        let movie = try libraryItem("Dune: Prophecy", type: .movie, tmdb: "90228")

        XCTAssertEqual(SeerrSearchMerge.libraryMatch(in: [movie, show], tmdbId: 90228, kind: .tv)?.id, show.id)
        XCTAssertNil(SeerrSearchMerge.libraryMatch(in: [movie], tmdbId: 1, kind: .movie))
    }
}
