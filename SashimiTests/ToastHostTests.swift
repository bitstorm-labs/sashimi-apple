import XCTest
@testable import Sashimi

/// Toasts above full-screen covers: every cover that raises toasts carries its
/// own overlay, and only the topmost overlay draws, so a toast is visible
/// above a cover and never twice.
@MainActor
final class ToastHostTests: XCTestCase {
    func testOnlyTheTopmostOverlayDrawsTheToast() {
        let toasts = ToastManager.shared
        let root = UUID()
        let cover = UUID()
        let coverOnCover = UUID()
        defer { [root, cover, coverOnCover].forEach(toasts.unregisterHost) }

        toasts.registerHost(root)
        XCTAssertTrue(toasts.isTopHost(root))

        toasts.registerHost(cover)
        XCTAssertFalse(toasts.isTopHost(root), "the root's overlay is under the cover")
        XCTAssertTrue(toasts.isTopHost(cover))

        toasts.registerHost(coverOnCover)
        XCTAssertFalse(toasts.isTopHost(cover))
        XCTAssertTrue(toasts.isTopHost(coverOnCover))

        toasts.unregisterHost(coverOnCover)
        XCTAssertTrue(toasts.isTopHost(cover))
        toasts.unregisterHost(cover)
        XCTAssertTrue(toasts.isTopHost(root), "back to the root once the covers close")
    }

    /// The presenter's overlay reappearing after a cover closes is top again,
    /// whatever order the two calls arrive in.
    func testAReappearingOverlayIsTopAgain() {
        let toasts = ToastManager.shared
        let root = UUID()
        let cover = UUID()
        defer { [root, cover].forEach(toasts.unregisterHost) }

        toasts.registerHost(root)
        toasts.registerHost(cover)
        toasts.unregisterHost(root) // the presenter "disappeared" under the cover
        XCTAssertTrue(toasts.isTopHost(cover))
        toasts.registerHost(root)   // it reappears as the cover closes...
        toasts.unregisterHost(cover) // ...before the cover's own disappear
        XCTAssertTrue(toasts.isTopHost(root))
        XCTAssertFalse(toasts.isTopHost(cover))
    }
}
