import XCTest
@testable import Sashimi

final class ThemeSongVisitStateTests: XCTestCase {
    func testFirstAppearanceStarts() {
        var s = ThemeSongVisitState()
        XCTAssertEqual(s.showAppeared(seriesId: "A"), .start(seriesId: "A"))
    }

    func testDrillingIntoSameShowDoesNotRestart() {
        // Series -> Season -> Episode is ONE visit. Each level presents a new
        // fullScreenCover, so this fires three times for one show.
        var s = ThemeSongVisitState()
        _ = s.showAppeared(seriesId: "A")
        XCTAssertEqual(s.showAppeared(seriesId: "A"), .ignore)
        XCTAssertEqual(s.showAppeared(seriesId: "A"), .ignore)
    }

    func testDifferentShowStartsAgain() {
        var s = ThemeSongVisitState()
        _ = s.showAppeared(seriesId: "A")
        XCTAssertEqual(s.showAppeared(seriesId: "B"), .start(seriesId: "B"))
    }

    func testReturningToTheSameShowAfterLeavingStartsAgain() {
        var s = ThemeSongVisitState()
        _ = s.showAppeared(seriesId: "A")
        XCTAssertEqual(s.detailDismissed(seriesId: "A"), .stop)
        XCTAssertEqual(s.showAppeared(seriesId: "A"), .start(seriesId: "A"))
    }

    func testDismissingAnInnerScreenDoesNotEndTheVisit() {
        // Backing out of Episode to Series is still the same visit; the theme
        // must not restart when the series screen becomes frontmost again.
        //
        // Deviation from the brief: the brief's version of this test omitted
        // the second showAppeared call that simulates drilling from Series
        // into Episode. Without it, this test's two-call prefix
        // (showAppeared, detailDismissed) is byte-for-byte identical to
        // testReturningToTheSameShowAfterLeavingStartsAgain's prefix, yet the
        // two tests asserted opposite outcomes for the state afterward -- a
        // contradiction no implementation could satisfy, since identical
        // inputs to a pure function must produce identical resulting state.
        // Added the missing drill-down call so this test actually exercises
        // "dismissing an inner screen" as its name and comment describe.
        var s = ThemeSongVisitState()
        _ = s.showAppeared(seriesId: "A")
        _ = s.showAppeared(seriesId: "A")
        XCTAssertEqual(s.detailDismissed(seriesId: "A"), .ignore)
        XCTAssertEqual(s.showAppeared(seriesId: "A"), .ignore)
    }

    func testNilSeriesIdNeverStarts() {
        // Movies and anything without a series key.
        var s = ThemeSongVisitState()
        XCTAssertEqual(s.showAppeared(seriesId: nil), .ignore)
    }

    func testResetClearsTheVisit() {
        var s = ThemeSongVisitState()
        _ = s.showAppeared(seriesId: "A")
        s.reset()
        XCTAssertEqual(s.showAppeared(seriesId: "A"), .start(seriesId: "A"))
    }
}
