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

    /// #875: every full-screen cover that raises toasts carries its own
    /// overlay, or its toasts draw under it at the app root. MediaDetailView
    /// also covers SeerrDetailView's library branch, which shows it as is.
    func testCoversThatRaiseToastsCarryTheirOwnOverlay() {
        let covers: [(String, Any.Type)] = [
            ("MediaDetailView", MediaDetailView.Body.self),
            ("SeasonDetailView", SeasonDetailView.Body.self),
            ("ListDetailView", ListDetailView.Body.self),
            // NewChannelForm's "Created" toast, inside either channel cover.
            ("ManageChannelsView", ManageChannelsView.Body.self),
            ("AddToChannelView", AddToChannelView.Body.self),
            ("SeerrDetailView", SeerrDetailView.Body.self),
            ("WatchlistPageView", WatchlistPageView.Body.self),
            ("AddToListView", AddToListView.Body.self)
        ]
        for (name, body) in covers {
            XCTAssertTrue(String(reflecting: body).contains("ToastModifier"),
                          "\(name) is shown as a full-screen cover and raises toasts, so it needs .toastOverlay()")
        }
    }
}
