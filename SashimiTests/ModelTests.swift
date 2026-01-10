import XCTest
@testable import Sashimi

final class ModelTests: XCTestCase {

    // MARK: - BaseItemDto Tests

    func testBaseItemDtoDecoding() throws {
        let json = """
        {
            "Id": "test-id-123",
            "Name": "Test Movie",
            "Type": "Movie",
            "ProductionYear": 2024,
            "RunTimeTicks": 72000000000,
            "Overview": "A test movie description",
            "CommunityRating": 8.5,
            "OfficialRating": "PG-13"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let item = try decoder.decode(BaseItemDto.self, from: json)

        XCTAssertEqual(item.id, "test-id-123")
        XCTAssertEqual(item.name, "Test Movie")
        XCTAssertEqual(item.type, .movie)
        XCTAssertEqual(item.productionYear, 2024)
        XCTAssertEqual(item.runTimeTicks, 72000000000)
        XCTAssertEqual(item.overview, "A test movie description")
        XCTAssertEqual(item.communityRating, 8.5)
        XCTAssertEqual(item.officialRating, "PG-13")
    }

    func testBaseItemDtoEpisodeDecoding() throws {
        let json = """
        {
            "Id": "episode-123",
            "Name": "Pilot",
            "Type": "Episode",
            "SeriesName": "Test Series",
            "SeriesId": "series-456",
            "SeasonId": "season-789",
            "IndexNumber": 1,
            "ParentIndexNumber": 1
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let item = try decoder.decode(BaseItemDto.self, from: json)

        XCTAssertEqual(item.id, "episode-123")
        XCTAssertEqual(item.name, "Pilot")
        XCTAssertEqual(item.type, .episode)
        XCTAssertEqual(item.seriesName, "Test Series")
        XCTAssertEqual(item.seriesId, "series-456")
        XCTAssertEqual(item.seasonId, "season-789")
        XCTAssertEqual(item.indexNumber, 1)
        XCTAssertEqual(item.parentIndexNumber, 1)
    }

    func testBaseItemDtoDisplayTitle() throws {
        // Movie should use its name
        let movie = BaseItemDto(
            id: "1", name: "Test Movie", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil
        )
        XCTAssertEqual(movie.displayTitle, "Test Movie")

        // Episode should use series name if available
        let episode = BaseItemDto(
            id: "2", name: "Episode Title", type: .episode,
            seriesName: "Series Name", seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: 1, parentIndexNumber: 1, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil
        )
        XCTAssertEqual(episode.displayTitle, "Series Name")
    }

    func testBaseItemDtoProgressPercent() throws {
        let userData = UserItemDataDto(
            playbackPositionTicks: 36000000000, // 1 hour
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil
        )

        let item = BaseItemDto(
            id: "1", name: "Test", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: 72000000000, // 2 hours total
            userData: userData, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil
        )

        XCTAssertEqual(item.progressPercent, 0.5, accuracy: 0.01)
    }

    // MARK: - ItemType Tests

    func testItemTypeRawValues() {
        XCTAssertEqual(ItemType.movie.rawValue, "Movie")
        XCTAssertEqual(ItemType.series.rawValue, "Series")
        XCTAssertEqual(ItemType.episode.rawValue, "Episode")
        XCTAssertEqual(ItemType.season.rawValue, "Season")
        XCTAssertEqual(ItemType.video.rawValue, "Video")
    }

    // MARK: - ContentRating Tests

    func testContentRatingSeverity() {
        XCTAssertLessThan(ContentRating.g.severity, ContentRating.pg.severity)
        XCTAssertLessThan(ContentRating.pg.severity, ContentRating.pg13.severity)
        XCTAssertLessThan(ContentRating.pg13.severity, ContentRating.r.severity)
        XCTAssertLessThan(ContentRating.r.severity, ContentRating.nc17.severity)
        XCTAssertLessThan(ContentRating.nc17.severity, ContentRating.any.severity)
    }

    func testContentRatingInitFromOfficialRating() {
        XCTAssertEqual(ContentRating(officialRating: "G"), .g)
        XCTAssertEqual(ContentRating(officialRating: "PG"), .pg)
        XCTAssertEqual(ContentRating(officialRating: "PG-13"), .pg13)
        XCTAssertEqual(ContentRating(officialRating: "R"), .r)
        XCTAssertEqual(ContentRating(officialRating: "NC-17"), .nc17)

        // TV ratings
        XCTAssertEqual(ContentRating(officialRating: "TV-G"), .g)
        XCTAssertEqual(ContentRating(officialRating: "TV-PG"), .pg)
        XCTAssertEqual(ContentRating(officialRating: "TV-14"), .pg13)
        XCTAssertEqual(ContentRating(officialRating: "TV-MA"), .r)

        // Unknown ratings should default to .any
        XCTAssertEqual(ContentRating(officialRating: "Unknown"), .any)
    }
}
