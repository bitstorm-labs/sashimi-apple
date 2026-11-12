import SwiftUI
import XCTest
@testable import Sashimi

/// The Spotlight backdrop fills its frame, so a 16:9 picture is drawn wider
/// than the frame (1536pt on a 1920×1080 page, not the frame's 1344pt). The
/// request has to cover that drawn width at the display's scale, or the
/// picture is upscaled and reads soft on the TV (owner, 2026-11-11).
final class SpotlightBackdropResolutionTests: XCTestCase {
    private let tv = CGSize(width: 1920, height: 1080)

    func testAFilledBackdropIsDrawnWiderThanItsFrame() {
        let layout = SpotlightBackdropLayout.landscape
        XCTAssertEqual(layout.frame(in: tv).width, 1344)
        XCTAssertEqual(layout.imagePointWidth(in: tv), 1536, accuracy: 0.5, "864pt tall × 16/9")
    }

    /// 1080p output (scale 1) and 4K output (scale 2): never less than the
    /// drawn pixels, so the picture is never upscaled.
    func testTheRequestCoversTheDrawnPixels() {
        let layout = SpotlightBackdropLayout.landscape
        for scale: CGFloat in [1, 2] {
            let drawn = Int((layout.imagePointWidth(in: tv) * scale).rounded(.up))
            XCTAssertGreaterThanOrEqual(layout.requestPixelWidth(in: tv, scale: scale), drawn, "scale \(scale)")
        }
        XCTAssertEqual(layout.requestPixelWidth(in: tv, scale: 1), 1560)
        XCTAssertEqual(layout.requestPixelWidth(in: tv, scale: 2), 3080)
    }

    /// Past a 4K screen's width there is nothing more to see.
    func testTheRequestIsCappedAtFourK() {
        let huge = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(SpotlightBackdropLayout.landscape.requestPixelWidth(in: huge, scale: 2), ImageSizing.maxSpotlightBackdropWidth)
        XCTAssertEqual(ImageSizing.maxSpotlightBackdropWidth, 3840)
    }

    /// Portrait (iPhone, iPad): the 3:2 frame is full width, and a 16:9
    /// picture filling it is wider still (262pt tall × 16/9 on an iPhone).
    func testPortraitRequestsTheFilledWidth() {
        let phone = CGSize(width: 393, height: 852)
        XCTAssertEqual(SpotlightBackdropLayout.portrait.imagePointWidth(in: phone), 465.8, accuracy: 0.5)
        XCTAssertEqual(SpotlightBackdropLayout.portrait.requestPixelWidth(in: phone, scale: 3), 1400)
    }

    /// Titles the server doesn't have: TMDB's size covering the request.
    func testTMDBBackdropSizeCoversTheRequest() {
        XCTAssertEqual(SeerrImages.backdrop("/a.jpg", pixelWidth: 700)?.absoluteString, "https://image.tmdb.org/t/p/w780/a.jpg")
        XCTAssertEqual(SeerrImages.backdrop("/a.jpg", pixelWidth: 1200)?.absoluteString, "https://image.tmdb.org/t/p/w1280/a.jpg")
        XCTAssertEqual(SeerrImages.backdrop("/a.jpg", pixelWidth: 1560)?.absoluteString, "https://image.tmdb.org/t/p/original/a.jpg")
        XCTAssertEqual(SeerrImages.backdrop("/a.jpg", pixelWidth: 3080)?.absoluteString, "https://image.tmdb.org/t/p/original/a.jpg")
    }
}
