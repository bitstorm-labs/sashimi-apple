import XCTest
@testable import Sashimi

/// Image requests ask for on-screen points × screen scale, so art is not
/// upscaled on a 4K TV / @3x phone and not over-fetched either.
@MainActor
final class ImageSizingTests: XCTestCase {
    func testPixelWidthIsPointsTimesScaleRoundedUpToFortyPixels() {
        XCTAssertEqual(ImageSizing.pixelWidth(points: 440, scale: 2), 880)   // tvOS Continue Watching card
        XCTAssertEqual(ImageSizing.pixelWidth(points: 220, scale: 2), 440)   // tvOS poster
        XCTAssertEqual(ImageSizing.pixelWidth(points: 180, scale: 3), 560)   // 540 → next 40px step
        XCTAssertEqual(ImageSizing.pixelWidth(points: 70, scale: 3), 240)    // 210 → 240
        XCTAssertEqual(ImageSizing.pixelWidth(points: 1, scale: 1), 40)      // never below one step
    }

    func testTVRendersAtTwoX() {
        XCTAssertEqual(ImageSizing.screenScale, 2)
        XCTAssertEqual(ImageSizing.pixelWidth(points: 740), 1480)
    }

    /// tvOS hero: a 1920×540pt (32:9) frame, 30pt top inset, 16:9 backdrop
    /// drawn `.fit` → ~907pt wide → 1840px (was a flat 1920).
    func testTVHeroRequestsTheDrawnWidth() {
        let layout = HeroLayout(imageTopInset: 30, accent: .red)
        let size = CGSize(width: 1920, height: 540)
        XCTAssertEqual(layout.displayedImagePoints(in: size), 510 * 16 / 9, accuracy: 0.01)
        XCTAssertEqual(layout.imagePixelWidth(in: size), 1840)
        XCTAssertEqual(layout.imagePixelWidth(in: .zero), 1920)
    }

    /// iPad portrait hero widens to fill its height: 834×600pt → full width.
    func testPadPortraitHeroWidensToFillHeight() {
        let layout = HeroLayout(widensImageToFillHeight: true, accent: .red)
        let size = CGSize(width: 834, height: 600)
        XCTAssertEqual(layout.displayedImagePoints(in: size), 834, accuracy: 0.01)
        XCTAssertEqual(ImageSizing.pixelWidth(points: layout.displayedImagePoints(in: size), scale: 2), 1680)
    }

    /// The up-next card is 740pt on tvOS; it used to request 960px.
    func testUpNextThumbnailRequestsFullTVResolution() throws {
        let json = #"{"Id":"ep1","Name":"Pilot","Type":"Episode","SeriesId":"s1"}"#
        let episode = try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "serverURL")
        defaults.set("http://jf.local:8096", forKey: "serverURL")
        defer { defaults.set(saved, forKey: "serverURL") }

        let urls = EpisodeUpNextScreen.serverImageURLs(for: episode, role: .thumbnail, serverID: nil)
        let widths = urls.map { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "maxWidth" }?.value
        }
        XCTAssertEqual(widths, ["1480", "1480", "1480"])
    }
}
