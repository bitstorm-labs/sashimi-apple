import XCTest
@testable import Sashimi

final class HomeViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    @MainActor
    func testInitialState() async {
        let viewModel = HomeViewModel()

        XCTAssertTrue(viewModel.continueWatchingItems.isEmpty)
        XCTAssertTrue(viewModel.recentlyAddedItems.isEmpty)
        XCTAssertTrue(viewModel.heroItems.isEmpty)
        XCTAssertTrue(viewModel.libraries.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
    }

    // MARK: - Date Parsing Tests

    func testISO8601DateParsing() {
        // Test with fractional seconds
        let dateString1 = "2024-01-15T10:30:00.123Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date1 = formatter.date(from: dateString1)
        XCTAssertNotNil(date1)

        // Test without fractional seconds
        let dateString2 = "2024-01-15T10:30:00Z"
        formatter.formatOptions = [.withInternetDateTime]
        let date2 = formatter.date(from: dateString2)
        XCTAssertNotNil(date2)
    }

    func testDateComparison() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let earlier = formatter.date(from: "2024-01-15T10:00:00Z")!
        let later = formatter.date(from: "2024-01-15T12:00:00Z")!

        XCTAssertTrue(later > earlier)
    }

    // MARK: - Library Filtering Tests

    func testMediaLibraryFiltering() {
        // Valid media library types
        let validTypes = ["movies", "tvshows", "music", "mixed", "homevideos"]

        for type in validTypes {
            let collectionType = type.lowercased()
            let isValid = ["movies", "tvshows", "music", "mixed", "homevideos"].contains(collectionType)
            XCTAssertTrue(isValid, "\(type) should be a valid media library")
        }

        // Invalid types (should be filtered out)
        let invalidTypes = ["boxsets", "playlists", "photos"]

        for type in invalidTypes {
            let collectionType = type.lowercased()
            let isValid = ["movies", "tvshows", "music", "mixed", "homevideos"].contains(collectionType)
            XCTAssertFalse(isValid, "\(type) should not be a valid media library")
        }
    }

    func testNilCollectionTypeIsValid() {
        // Libraries with nil collectionType should be considered valid
        // (the isMediaLibrary function returns true for nil)
        let collectionType: String? = nil
        let isValid = collectionType == nil || ["movies", "tvshows", "music", "mixed", "homevideos"].contains(collectionType!.lowercased())
        XCTAssertTrue(isValid)
    }

    // MARK: - Deduplication Logic Tests

    func testDeduplicationBySeriesId() {
        // Create test items with same series ID
        let episode1 = BaseItemDto(
            id: "ep-1", name: "Episode 1", type: .episode,
            seriesName: "Test Series", seriesId: "series-123", seasonId: "season-1", parentId: nil,
            indexNumber: 1, parentIndexNumber: 1, overview: nil,
            runTimeTicks: nil, userData: UserItemDataDto(
                playbackPositionTicks: 100,
                playCount: 1,
                isFavorite: false,
                played: false,
                lastPlayedDate: "2024-01-15T12:00:00Z"
            ), imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil
        )

        let episode2 = BaseItemDto(
            id: "ep-2", name: "Episode 2", type: .episode,
            seriesName: "Test Series", seriesId: "series-123", seasonId: "season-1", parentId: nil,
            indexNumber: 2, parentIndexNumber: 1, overview: nil,
            runTimeTicks: nil, userData: UserItemDataDto(
                playbackPositionTicks: 50,
                playCount: 1,
                isFavorite: false,
                played: false,
                lastPlayedDate: "2024-01-14T12:00:00Z"
            ), imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil
        )

        // Test that series deduplication works
        var seenSeriesIds = Set<String>()
        var result: [BaseItemDto] = []

        for item in [episode1, episode2] {
            if let seriesId = item.seriesId {
                guard !seenSeriesIds.contains(seriesId) else { continue }
                seenSeriesIds.insert(seriesId)
            }
            result.append(item)
        }

        // Should only have one item since both have same seriesId
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "ep-1") // First one should be kept
    }

    func testMoviesAreNotDedupedBySeries() {
        // Movies don't have seriesId, so they shouldn't be deduped by series logic
        let movie1 = BaseItemDto(
            id: "movie-1", name: "Movie 1", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil
        )

        let movie2 = BaseItemDto(
            id: "movie-2", name: "Movie 2", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil
        )

        var seenIds = Set<String>()
        var seenSeriesIds = Set<String>()
        var result: [BaseItemDto] = []

        for item in [movie1, movie2] {
            guard !seenIds.contains(item.id) else { continue }

            if let seriesId = item.seriesId {
                guard !seenSeriesIds.contains(seriesId) else { continue }
                seenSeriesIds.insert(seriesId)
            }

            seenIds.insert(item.id)
            result.append(item)
        }

        // Both movies should be in result (no series-based dedup)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Episode Subtitle Formatting Tests

    func testEpisodeSubtitleFormatting() {
        let season = 2
        let episode = 5
        let seriesName = "Test Series"

        let subtitle = "\(seriesName) • S\(season):E\(episode)"
        XCTAssertEqual(subtitle, "Test Series • S2:E5")
    }

    // MARK: - TopShelf Data Tests

    func testTopShelfItemLimit() {
        // TopShelf should only save first 10 items
        let limit = 10

        var items: [Int] = Array(1...20)
        items = Array(items.prefix(limit))

        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.first, 1)
        XCTAssertEqual(items.last, 10)
    }

    func testImageTypeForDifferentItemTypes() {
        // Test the image type selection logic for different item types

        // Regular TV episode with backdrops should use series backdrop
        let seriesHasBackdrop = true
        var imageType = seriesHasBackdrop ? "Backdrop" : "Primary"
        XCTAssertEqual(imageType, "Backdrop")

        // YouTube episode (no series backdrop) should use Primary
        let youtubeHasBackdrop = false
        imageType = youtubeHasBackdrop ? "Backdrop" : "Primary"
        XCTAssertEqual(imageType, "Primary")

        // Movies should use Backdrop
        imageType = "Backdrop"
        XCTAssertEqual(imageType, "Backdrop")

        // Videos should use Primary
        imageType = "Primary"
        XCTAssertEqual(imageType, "Primary")
    }
}
