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
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let before = scene.statusBarManager?.isStatusBarHidden
        window.rootViewController = UIHostingController(rootView: Presenter(item: Self.item))
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let during = scene.statusBarManager?.isStatusBarHidden
        window.isHidden = true
        XCTAssertEqual(before, false, "precondition: the presenter shows the status bar")
        XCTAssertEqual(during, true, "the player hides the status bar, controls up or not")
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
