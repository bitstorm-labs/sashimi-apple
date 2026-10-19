import XCTest
@testable import Sashimi

/// When Home's hero takes focus after launch (#725): a deep-linked player or
/// detail that covers Home before the hero is ready must not swallow the
/// one-shot handoff, or Home comes back with nothing focused.
final class HomeFocusHandoffTests: XCTestCase {
    /// MainTabView stops asking once it arms its edge guard; until then a
    /// second hero update hands focus off again, as it did before #725.
    func testPlainLaunchHandsOff() {
        var handoff = HomeFocusHandoff()
        XCTAssertTrue(handoff.heroReady(onHome: true, viewerNavigatedRail: false))
        XCTAssertTrue(handoff.isDone)
        XCTAssertTrue(handoff.heroReady(onHome: true, viewerNavigatedRail: false))
        XCTAssertFalse(handoff.heroReady(onHome: true, viewerNavigatedRail: true), "the viewer moved: stop")
        XCTAssertFalse(handoff.heroReady(onHome: true, viewerNavigatedRail: false))
    }

    func testViewerInTheRailIsNeverYanked() {
        var handoff = HomeFocusHandoff()
        XCTAssertFalse(handoff.heroReady(onHome: true, viewerNavigatedRail: true))
        XCTAssertTrue(handoff.isDone)
    }

    func testAnotherSectionWaitsForHome() {
        var handoff = HomeFocusHandoff()
        XCTAssertFalse(handoff.heroReady(onHome: false, viewerNavigatedRail: false))
        XCTAssertFalse(handoff.isDone)
    }

    /// The #725 sequence: Top Shelf cold launch puts the player up first,
    /// the hero loads underneath, Back closes the player.
    func testHeroReadyUnderADeepLinkWaitsForTheDismissal() {
        var handoff = HomeFocusHandoff()
        handoff.coverPresented()
        XCTAssertFalse(handoff.heroReady(onHome: true, viewerNavigatedRail: false), "a reset under the cover is lost")
        XCTAssertFalse(handoff.heroReady(onHome: true, viewerNavigatedRail: false), "still covered")
        XCTAssertFalse(handoff.isDone, "the edge guard stays unarmed while deferred")
        XCTAssertTrue(handoff.coverDismissed(onHome: true))
        XCTAssertTrue(handoff.isDone)
        XCTAssertFalse(handoff.coverDismissed(onHome: true), "only once")
    }

    /// Hero ready first, deep link second: focus was handed off and tvOS
    /// returns it to the hero on its own when the cover closes.
    func testCoverAfterTheHandoffLeavesFocusAlone() {
        var handoff = HomeFocusHandoff()
        XCTAssertTrue(handoff.heroReady(onHome: true, viewerNavigatedRail: false))
        handoff.coverPresented()
        XCTAssertFalse(handoff.coverDismissed(onHome: true))
    }

    func testCoverClosedBeforeTheHeroLoadsHandsOffNormally() {
        var handoff = HomeFocusHandoff()
        handoff.coverPresented()
        XCTAssertFalse(handoff.coverDismissed(onHome: true))
        XCTAssertTrue(handoff.heroReady(onHome: true, viewerNavigatedRail: false))
    }

    func testDeferredHandoffOffHomeFinishesWithoutMoving() {
        var handoff = HomeFocusHandoff()
        handoff.coverPresented()
        _ = handoff.heroReady(onHome: true, viewerNavigatedRail: false)
        XCTAssertFalse(handoff.coverDismissed(onHome: false))
        XCTAssertTrue(handoff.isDone)
    }
}
