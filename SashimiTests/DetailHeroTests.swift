import XCTest
@testable import Sashimi

/// The season page shows its series' backdrop and trailer, exactly as the
/// series page does (#764); the other pages keep their pictures.
final class DetailHeroTests: XCTestCase {
    private func item(_ json: String) throws -> BaseItemDto {
        try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }

    private var series: BaseItemDto {
        get throws { try item(#"{"Id":"show","Name":"Show","Type":"Series","BackdropImageTags":["b1"]}"#) }
    }

    /// A season straight from /Shows/{id}/Seasons: no backdrop tags at all.
    private var bareSeason: BaseItemDto {
        get throws { try item(#"{"Id":"s2","Name":"Season 2","Type":"Season","SeriesId":"show"}"#) }
    }

    func testTheSeasonPageShowsTheSeriesPagesPictureOnAppleTV() throws {
        let seasonHero = DetailHero.tvImage(for: try bareSeason, isYouTubeSeries: false)
        XCTAssertEqual(seasonHero, DetailHero.Image(itemId: "show", type: "Backdrop"))
        XCTAssertEqual(seasonHero, DetailHero.tvImage(for: try series, isYouTubeSeries: false))
    }

    func testTheSeasonPageShowsTheSeriesBackdropOnIPhoneAndIPad() throws {
        // Without parent tags the old rule fell back to the season's own poster.
        XCTAssertEqual(
            DetailHero.mobileImage(for: try bareSeason, isYouTubeSeries: false),
            DetailHero.Image(itemId: "show", type: "Backdrop")
        )
        XCTAssertEqual(
            DetailHero.mobileImage(for: try bareSeason, isYouTubeSeries: false),
            DetailHero.mobileImage(for: try series, isYouTubeSeries: false)
        )
    }

    func testAYouTubeChannelsSeasonShowsTheChannelBanner() throws {
        XCTAssertEqual(
            DetailHero.tvImage(for: try bareSeason, isYouTubeSeries: true),
            DetailHero.Image(itemId: "show", type: "Banner")
        )
        XCTAssertEqual(
            DetailHero.mobileImage(for: try bareSeason, isYouTubeSeries: true),
            DetailHero.Image(itemId: "show", type: "Banner")
        )
    }

    func testTheSeasonPagePlaysTheSeriesTrailer() throws {
        let season = try bareSeason
        XCTAssertEqual(HeroTrailerPolicy.trailerSourceId(for: season), "show")
        XCTAssertEqual(HeroTrailerPolicy.kind(for: season), .series)
    }

    func testOtherPagesKeepTheirPictures() throws {
        let episode = try item(#"{"Id":"e1","Name":"E1","Type":"Episode","SeriesId":"show","ParentBackdropImageTags":["p"]}"#)
        let movie = try item(#"{"Id":"m","Name":"M","Type":"Movie","BackdropImageTags":["b"]}"#)
        let posterOnly = try item(#"{"Id":"m2","Name":"M2","Type":"Movie"}"#)
        XCTAssertEqual(DetailHero.tvImage(for: episode, isYouTubeSeries: false), DetailHero.Image(itemId: "e1", type: "Primary"))
        XCTAssertEqual(DetailHero.mobileImage(for: episode, isYouTubeSeries: false), DetailHero.Image(itemId: "e1", type: "Primary"))
        XCTAssertEqual(DetailHero.tvImage(for: movie, isYouTubeSeries: false), DetailHero.Image(itemId: "m", type: "Backdrop"))
        XCTAssertEqual(DetailHero.mobileImage(for: movie, isYouTubeSeries: false), DetailHero.Image(itemId: "m", type: "Backdrop"))
        XCTAssertEqual(DetailHero.mobileImage(for: posterOnly, isYouTubeSeries: false), DetailHero.Image(itemId: "m2", type: "Primary"))
        XCTAssertEqual(DetailHero.tvImage(for: try series, isYouTubeSeries: true), DetailHero.Image(itemId: "show", type: "Banner"))
        XCTAssertEqual(DetailHero.tvFallbackTypes(isYouTubeSeries: false), ["Thumb", "Backdrop", "Primary"])
    }
}
