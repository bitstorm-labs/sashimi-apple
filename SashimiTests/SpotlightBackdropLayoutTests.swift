import SwiftUI
import XCTest
@testable import Sashimi

/// Detail pages take the Watchlist Spotlight's backdrop coverage (#894): one
/// layout, so the list pages and every detail page cover the same area.
final class SpotlightBackdropLayoutTests: XCTestCase {
    /// The coverage the owner approved on the Watchlist page: bright across
    /// the right two thirds, fading in from the left and over the lower half.
    func testLandscapeIsTheWatchlistSpotlightsCoverage() {
        let layout = SpotlightBackdropLayout.landscape
        XCTAssertEqual(layout.frame(in: CGSize(width: 1920, height: 1080)), CGSize(width: 1344, height: 864))
        XCTAssertEqual(layout.leadingOpaqueAt, 0.45)
        XCTAssertEqual(layout.bottomFadeStartsAt, 0.5)
        XCTAssertNil(layout.maxHeightPerWidth)
    }

    /// iPhone and a portrait iPad: the whole width, across the top, never
    /// taller than 3:2 so a 16:9 backdrop keeps most of its picture.
    func testPortraitCoversTheTopAtFullWidth() {
        let layout = SpotlightBackdropLayout.portrait
        XCTAssertEqual(layout.leadingOpaqueAt, 0, "the left edge is the screen's: nothing to fade into")
        let phone = layout.frame(in: CGSize(width: 393, height: 852))
        XCTAssertEqual(phone.width, 393)
        XCTAssertEqual(phone.height, 262, accuracy: 0.01)
        let ipad = layout.frame(in: CGSize(width: 820, height: 1180))
        XCTAssertEqual(ipad.width, 820)
        XCTAssertEqual(ipad.height, 546.67, accuracy: 0.01)
        // Short and wide: the page height caps it first.
        XCTAssertEqual(layout.frame(in: CGSize(width: 900, height: 500)).height, 300, accuracy: 0.01)
    }

    func testTheLayoutFollowsThePagesShape() {
        XCTAssertEqual(SpotlightBackdropLayout.fitting(CGSize(width: 1180, height: 820)), .landscape)
        XCTAssertEqual(SpotlightBackdropLayout.fitting(CGSize(width: 820, height: 1180)), .portrait)
        XCTAssertEqual(SpotlightBackdropLayout.fitting(CGSize(width: 1920, height: 1080)), .landscape)
    }
}

extension SpotlightBackdropLayoutTests {
    /// Portrait pages start their details over the picture's faded lower
    /// part; landscape ones beside it, from the top.
    func testDetailsStartOverTheFadeInPortraitOnly() {
        XCTAssertEqual(SpotlightBackdropLayout.landscape.contentInset(in: CGSize(width: 1180, height: 820)), 0)
        XCTAssertEqual(SpotlightBackdropLayout.portrait.contentInset(in: CGSize(width: 820, height: 1180)), 410, accuracy: 0.01)
        let start = SpotlightBackdropLayout.portrait.contentStartsAt ?? 0
        XCTAssertGreaterThan(start, SpotlightBackdropLayout.portrait.bottomFadeStartsAt, "the details sit on the faded part")
    }
}
