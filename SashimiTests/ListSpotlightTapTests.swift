import XCTest
@testable import Sashimi

/// iPhone, iPad and Mac list pages: a tap shows a title in the Spotlight
/// first, as focus does on Apple TV; it opens only once it's shown.
final class ListSpotlightTapTests: XCTestCase {
    func testTappingAnotherTitleShowsItInTheSpotlight() {
        XCTAssertEqual(ListSpotlightTap.tapped("dune", shownId: "bear"), .select("dune"))
    }

    func testTappingTheShownTitleOpensIt() {
        XCTAssertEqual(ListSpotlightTap.tapped("bear", shownId: "bear"), .open)
    }

    func testTappingWithNothingShownSelects() {
        XCTAssertEqual(ListSpotlightTap.tapped("bear", shownId: nil), .select("bear"))
    }
}

/// The list page's header on iPhone, iPad and Mac uses the detail pages'
/// Spotlight coverage, so a wide page no longer ends the picture part-way
/// across with a hard edge.
final class MobileListSpotlightHeaderLayoutTests: XCTestCase {
    private let iPadLandscape = CGSize(width: 1366, height: 950)
    private let iPhonePortrait = CGSize(width: 402, height: 780)

    func testALandscapePagePutsThePictureFlushRight() {
        let layout = SpotlightBackdropLayout.fitting(iPadLandscape)
        XCTAssertEqual(layout, .landscape)
        // Flush to the right edge: the picture's frame ends at the page's.
        XCTAssertEqual(layout.frame(in: iPadLandscape).width, iPadLandscape.width * 0.7, accuracy: 0.5)
        // A 16:9 backdrop fills it rather than stopping short of the edge.
        XCTAssertGreaterThanOrEqual(layout.imagePointWidth(in: iPadLandscape), layout.frame(in: iPadLandscape).width)
    }

    func testALandscapePageKeepsTheDetailsOnTheDarkLeftSide() {
        let layout = SpotlightBackdropLayout.fitting(iPadLandscape)
        XCTAssertEqual(layout.detailsMaxWidth(in: iPadLandscape), 683, accuracy: 0.5)
        XCTAssertEqual(layout.contentInset(in: iPadLandscape), 0)
    }

    func testAPortraitPageRunsThePictureFullWidthWithDetailsUnderIt() {
        let layout = SpotlightBackdropLayout.fitting(iPhonePortrait)
        XCTAssertEqual(layout, .portrait)
        XCTAssertEqual(layout.frame(in: iPhonePortrait).width, iPhonePortrait.width)
        XCTAssertEqual(layout.detailsMaxWidth(in: iPhonePortrait), iPhonePortrait.width)
        XCTAssertGreaterThan(layout.contentInset(in: iPhonePortrait), 0)
    }

    func testPostersStartBelowThePicturesBrightPart() {
        for size in [iPadLandscape, iPhonePortrait] {
            let layout = SpotlightBackdropLayout.fitting(size)
            let height = layout.frame(in: size).height
            XCTAssertGreaterThan(layout.detailsMinHeight(in: size), height * layout.bottomFadeStartsAt)
            XCTAssertLessThan(layout.detailsMinHeight(in: size), height)
        }
    }
}
