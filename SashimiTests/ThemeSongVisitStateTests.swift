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

    /// Pins the real invariant a `NavigationStack` push/pop depends on:
    /// SwiftUI inserts the incoming view before removing the outgoing one,
    /// in BOTH directions. On push, the pushed (incoming) child's
    /// `onAppear` fires before the parent's (outgoing) `onDisappear`; on
    /// pop, the reappearing (incoming) parent's `onAppear` fires before the
    /// popped (outgoing) child's `onDisappear`. `depth` therefore goes
    /// 1 -> 2 -> 1 on push and 1 -> 2 -> 1 again on pop — it never reaches
    /// zero, so the visit never ends and never spuriously restarts.
    ///
    /// This is NOT the same claim as `fullScreenCover` parity (the parent
    /// never disappearing at all, per the doc comment on the type above) —
    /// pushing over a `NavigationStack` DOES fire the parent's
    /// `onDisappear`, confirmed empirically. What saves this from
    /// restarting the theme is purely the incoming-before-outgoing
    /// ordering pinned here. If a future SwiftUI version ever inverted
    /// that ordering (outgoing before incoming), `depth` would hit zero on
    /// push, `currentSeriesId` would clear, and the pop would return
    /// `.start` — restarting the theme every time someone backs out of an
    /// episode to its series.
    func testIncomingBeforeOutgoingOnBothPushAndPopNeverEndsTheVisit() {
        var s = ThemeSongVisitState()
        _ = s.showAppeared(seriesId: "S") // initial screen (e.g. Series) starts the visit

        // Push: the pushed child appears before the parent disappears.
        XCTAssertEqual(s.showAppeared(seriesId: "S"), .ignore, "child appearing mid-push must not read as a new visit")
        XCTAssertEqual(s.detailDismissed(seriesId: "S"), .ignore, "parent disappearing after the child already appeared must not end the visit")

        // Pop: the parent reappears before the popped child disappears.
        XCTAssertEqual(s.showAppeared(seriesId: "S"), .ignore, "parent reappearing mid-pop must not read as a new visit")
        XCTAssertEqual(s.detailDismissed(seriesId: "S"), .ignore, "child disappearing after the parent already reappeared must not end the visit")
    }
}
