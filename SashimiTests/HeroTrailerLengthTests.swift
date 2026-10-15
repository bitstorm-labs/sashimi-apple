import XCTest
@testable import Sashimi

/// How long the hero trailer plays: a movie's to its end, a series' with its
/// theme song (or 30 s without one).
final class HeroTrailerLengthTests: XCTestCase {
    func testAMovieTrailerPlaysToItsNaturalEnd() {
        XCTAssertEqual(HeroTrailerPolicy.clip(trailerSeconds: 121, kind: .movie), HeroTrailerClip(start: 10, end: 121))
        XCTAssertEqual(HeroTrailerPolicy.clip(trailerSeconds: 20, kind: .movie), HeroTrailerClip(start: 0, end: 20))
    }

    func testAMovieTrailerOfUnknownLengthPlaysUntilTheItemEnds() {
        XCTAssertEqual(HeroTrailerPolicy.clip(trailerSeconds: nil, kind: .movie), HeroTrailerClip(start: 0, end: .infinity))
    }

    func testUnderAThemeASeriesTrailerRunsUpToItsOwnEnd() {
        XCTAssertEqual(HeroTrailerPolicy.followingTheme(trailerSeconds: 121), HeroTrailerClip(start: 10, end: 121),
                       "a theme that outlasts the trailer finishes alone")
        XCTAssertEqual(HeroTrailerPolicy.followingTheme(trailerSeconds: nil), HeroTrailerClip(start: 0, end: .infinity))
    }

    func testASeriesTrailerFadesOutWithTheTheme() {
        XCTAssertEqual(
            HeroTrailerPolicy.afterThemeEnded(trailerSeconds: 121, position: 55, crossFade: 0.6),
            HeroTrailerClip(start: 10, end: 55.6),
            "the fade starts as the theme's does"
        )
    }

    func testASeriesTrailerPlaysAtLeastTwentySecondsUnderATheme() {
        XCTAssertEqual(
            HeroTrailerPolicy.afterThemeEnded(trailerSeconds: 121, position: 18, crossFade: 0.6),
            HeroTrailerClip(start: 10, end: 30),
            "20 s of video from the start point, not 20 s into the file"
        )
        XCTAssertEqual(
            HeroTrailerPolicy.afterThemeEnded(trailerSeconds: 40, position: 3, crossFade: 0.6),
            HeroTrailerClip(start: 0, end: 20)
        )
    }

    func testTheMinimumNeverRunsPastTheTrailer() {
        XCTAssertEqual(
            HeroTrailerPolicy.afterThemeEnded(trailerSeconds: 15, position: 5, crossFade: 0.6),
            HeroTrailerClip(start: 0, end: 15)
        )
        XCTAssertEqual(
            HeroTrailerPolicy.afterThemeEnded(trailerSeconds: 60, position: 59.9, crossFade: 0.6),
            HeroTrailerClip(start: 10, end: 60)
        )
    }
}
