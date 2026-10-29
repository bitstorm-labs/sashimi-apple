import XCTest
@testable import SashimiMobile

/// #799: the Mac player hides the pointer with its controls during
/// playback, and keeps it whenever something wants it.
final class PlayerPointerPolicyTests: XCTestCase {
    // swiftlint:disable:next function_parameter_count
    private func hides(
        isMac: Bool = true,
        isPlaying: Bool = true,
        controlsVisible: Bool = false,
        menuOpen: Bool = false,
        pointerInside: Bool = true,
        appActive: Bool = true
    ) -> Bool {
        PlayerPointerState(
            isMac: isMac,
            isPlaying: isPlaying,
            controlsVisible: controlsVisible,
            menuOpen: menuOpen,
            pointerInside: pointerInside,
            appActive: appActive
        ).hidesPointer
    }

    func testPlayingWithControlsHiddenHidesThePointer() {
        XCTAssertTrue(hides())
    }

    func testVisibleControlsKeepThePointer() {
        XCTAssertFalse(hides(controlsVisible: true))
    }

    func testPausedKeepsThePointer() {
        XCTAssertFalse(hides(isPlaying: false))
    }

    func testAnOpenMenuKeepsThePointer() {
        XCTAssertFalse(hides(menuOpen: true))
    }

    func testPointerOutsideThePlayerIsLeftAlone() {
        XCTAssertFalse(hides(pointerInside: false))
    }

    func testAnotherAppInFrontKeepsThePointer() {
        XCTAssertFalse(hides(appActive: false))
    }

    /// iPhone and iPad have no pointer to hide (an iPad trackpad keeps its own).
    func testIPhoneAndIPadNeverHide() {
        XCTAssertFalse(hides(isMac: false))
    }
}
