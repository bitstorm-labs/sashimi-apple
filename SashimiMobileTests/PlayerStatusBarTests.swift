import SwiftUI
import XCTest
@testable import SashimiMobile

/// The player's top band has its own clock; the system status bar (time,
/// Wi-Fi, battery) must stay hidden for as long as the player is presented.
@MainActor
final class PlayerStatusBarTests: XCTestCase {
    private struct Presenter: View {
        @State var item: BaseItemDto?
        var body: some View { Color.gray.fullScreenPlayer(item: $item) }
    }

    func testStatusBarHiddenWhilePlayerPresented() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: Presenter(item: nil))
        window.makeKeyAndVisible()
        let statusBar = try XCTUnwrap(scene.statusBarManager)
        let before = Self.status(of: statusBar, settlingOn: false, within: 5)
        window.rootViewController = UIHostingController(rootView: Presenter(item: Self.item))
        let during = Self.status(of: statusBar, settlingOn: true, within: 15)
        window.isHidden = true
        XCTAssertEqual(before, false, "precondition: the presenter shows the status bar")
        XCTAssertEqual(during, true, "the player hides the status bar, controls up or not")
    }

    /// Runs the run loop until the status bar reaches `expected` or `timeout`
    /// passes, then reports what it is. A fixed wait read it too early on a
    /// slow CI runner (#853).
    private static func status(of statusBar: UIStatusBarManager, settlingOn expected: Bool, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while statusBar.isStatusBarHidden != expected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return statusBar.isStatusBarHidden
    }

    private static let item = BaseItemDto(
        id: "ep", name: "T", type: .movie, seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
        indexNumber: nil, parentIndexNumber: nil, overview: nil, runTimeTicks: nil, userData: nil, imageTags: nil,
        backdropImageTags: nil, parentBackdropImageTags: nil, primaryImageAspectRatio: nil, mediaType: nil,
        libraryName: nil, productionYear: nil, communityRating: nil, officialRating: nil, genres: nil, taglines: nil,
        people: nil, criticRating: nil, premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
        localTrailerCount: nil, mediaStreams: nil
    )
}
