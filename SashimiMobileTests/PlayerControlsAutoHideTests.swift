import XCTest
@testable import SashimiMobile

/// #807: the player's controls faded under an open Audio or Subtitles menu.
/// The idle timer holds while a menu is open and starts again when it closes.
final class PlayerControlsAutoHideTests: XCTestCase {
    private func state(
        controlsVisible: Bool = true,
        isScrubbing: Bool = false,
        menuOpen: Bool = false
    ) -> PlayerControlsAutoHide {
        PlayerControlsAutoHide(controlsVisible: controlsVisible, isScrubbing: isScrubbing, menuOpen: menuOpen)
    }

    func testVisibleIdleControlsCountDownAndHide() {
        XCTAssertTrue(state().runsIdleTimer)
        XCTAssertEqual(state().timeout, .hide)
    }

    func testAnOpenMenuStopsTheCountdown() {
        XCTAssertFalse(state(menuOpen: true).runsIdleTimer)
    }

    /// The tap that opens a pill restarts the timer just before the menu
    /// opens, so the timer can fire with the menu up: it must not hide then.
    func testATimerThatFiresWhileAMenuIsOpenWaitsForItToClose() {
        XCTAssertEqual(state(menuOpen: true).timeout, .waitForMenuToClose)
    }

    func testScrubbingStillStopsTheCountdown() {
        XCTAssertFalse(state(isScrubbing: true).runsIdleTimer)
        XCTAssertEqual(state(isScrubbing: true).timeout, .stop)
        XCTAssertEqual(state(isScrubbing: true, menuOpen: true).timeout, .stop)
    }

    func testHiddenControlsHaveNothingToHide() {
        XCTAssertFalse(state(controlsVisible: false).runsIdleTimer)
        XCTAssertEqual(state(controlsVisible: false, menuOpen: true).timeout, .stop)
    }

    func testOpeningAMenuStopsTheTimerAndClosingItRestartsIt() {
        XCTAssertEqual(PlayerControlsAutoHide.transition(menuOpen: true), .stopTimer)
        XCTAssertEqual(PlayerControlsAutoHide.transition(menuOpen: false), .revealAndRestartTimer)
    }

    func testOnceTheMenuClosesTheControlsCountDownAndHideAgain() {
        var autoHide = state(menuOpen: true)
        XCTAssertFalse(autoHide.runsIdleTimer)
        autoHide.menuOpen = false
        XCTAssertTrue(autoHide.runsIdleTimer)
        XCTAssertEqual(autoHide.timeout, .hide)
    }

    /// iPhone and iPad: an open pill menu is a view controller presented over
    /// the player, which is what the probe looks for.
    @MainActor
    func testProbeSeesAPresentationOverThePlayer() throws {
        let probe = PlayerPresentationProbe()
        let host = UIViewController()
        XCTAssertFalse(probe.isShowingPresentation, "no anchor yet")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let child = UIViewController()
        host.addChild(child)
        host.view.addSubview(child.view)
        child.didMove(toParent: host)
        let anchorView = UIView()
        child.view.addSubview(anchorView)
        probe.attach(anchorView)
        XCTAssertFalse(probe.isShowingPresentation)

        let menu = UIViewController()
        host.present(menu, animated: false)
        XCTAssertTrue(probe.isShowingPresentation, "a menu presented over the player's container")
        menu.dismiss(animated: false)
        XCTAssertFalse(probe.isShowingPresentation)
        window.isHidden = true
    }
}
