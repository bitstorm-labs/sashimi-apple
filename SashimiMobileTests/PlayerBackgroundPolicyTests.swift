import SwiftUI
import XCTest
@testable import SashimiMobile

/// #774 and #775: what leaving the app does to the player, and the Mac's
/// full-screen pill.
final class PlayerBackgroundPolicyTests: XCTestCase {
    func testIPhoneAndIPadStopWhenTheAppGoesToTheBackground() {
        XCTAssertTrue(PlayerBackgroundPolicy.stopsPlayback(phase: .background, isPictureInPictureActive: false, isMac: false))
    }

    func testPictureInPictureKeepsPlaying() {
        XCTAssertFalse(PlayerBackgroundPolicy.stopsPlayback(phase: .background, isPictureInPictureActive: true, isMac: false))
    }

    /// Switching apps on the Mac backgrounds the scene; the player must stay.
    func testTheMacKeepsThePlayerWhenAnotherAppIsInFront() {
        XCTAssertFalse(PlayerBackgroundPolicy.stopsPlayback(phase: .background, isPictureInPictureActive: false, isMac: true))
    }

    func testInactiveIsNotLeaving() {
        XCTAssertFalse(PlayerBackgroundPolicy.stopsPlayback(phase: .inactive, isPictureInPictureActive: false, isMac: false))
    }

    func testFullScreenPillNamesWhatItWillDo() {
        let windowed = PlayerFullScreenControl(isFullScreen: false, toggle: {})
        let fullScreen = PlayerFullScreenControl(isFullScreen: true, toggle: {})
        XCTAssertEqual(windowed.title, "Enter Full Screen")
        XCTAssertEqual(fullScreen.title, "Exit Full Screen")
        XCTAssertNotEqual(windowed.systemImage, fullScreen.systemImage)
    }
}
