import XCTest
@testable import Sashimi

/// Channel cards and channel hero slides pick landscape art in Roku's order.
final class ChannelArtworkTests: XCTestCase {
    private func item(
        type: ItemType = .episode,
        seriesId: String? = "series",
        imageTags: [String: String]? = nil,
        backdrops: [String]? = nil,
        parentBackdrops: [String]? = nil
    ) -> BaseItemDto {
        BaseItemDto(
            id: "episode", name: "x", type: type,
            seriesName: nil, seriesId: seriesId, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: imageTags,
            backdropImageTags: backdrops, parentBackdropImageTags: parentBackdrops,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    func testSeriesWithBackdropUsesSeriesBackdrop() {
        let art = item(imageTags: ["Primary": "p"], parentBackdrops: ["b"]).channelArtwork
        XCTAssertEqual(art.itemId, "series")
        XCTAssertEqual(art.imageType, "Backdrop")
    }

    /// The Golden Hour bug: a YouTube channel series has no backdrop, and its
    /// episode's only art is the thumbnail stored as Primary.
    func testYouTubeEpisodeUsesItsOwnThumbnail() {
        let art = item(imageTags: ["Primary": "p"], parentBackdrops: nil).channelArtwork
        XCTAssertEqual(art.itemId, "episode")
        XCTAssertEqual(art.imageType, "Primary")
    }

    func testMovieUsesItsOwnBackdrop() {
        let art = item(type: .movie, seriesId: nil, imageTags: ["Primary": "p"], backdrops: ["b"]).channelArtwork
        XCTAssertEqual(art.itemId, "episode")
        XCTAssertEqual(art.imageType, "Backdrop")
    }

    func testNoArtFallsBackToSeriesPoster() {
        let art = item(imageTags: nil).channelArtwork
        XCTAssertEqual(art.itemId, "series")
        XCTAssertEqual(art.imageType, "Primary")
    }
}

/// YouTube "episodes" (year as season, date as episode) never show S/E numbers.
final class DatedEpisodeTests: XCTestCase {
    func testYouTubeNumberingIsDated() {
        XCTAssertTrue(BaseItemDto.isDatedEpisode(season: 2025, episode: 102999))
    }

    func testOrdinaryNumberingIsNot() {
        XCTAssertFalse(BaseItemDto.isDatedEpisode(season: 5, episode: 10))
        XCTAssertFalse(BaseItemDto.isDatedEpisode(season: 1999, episode: 12))
    }

    func testGuideLabelUsesTheVideoTitleForDatedEpisodes() {
        XCTAssertEqual(GuideRow.episodeLabel(season: 2025, episode: 102999, title: "I Made a Choice"), "I Made a Choice")
        XCTAssertEqual(GuideRow.episodeLabel(season: 2, episode: 25, title: "x"), "S2E25")
    }
}
