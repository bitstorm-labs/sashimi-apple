import AVFoundation
import UIKit
import XCTest
@testable import Sashimi

@MainActor
final class VideoViewModeStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VideoViewModeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallOpensInNormal() {
        let store = VideoViewModeStore(defaults: defaults)
        XCTAssertNil(store.sessionMode)
        XCTAssertEqual(store.defaultMode, .normal)
        XCTAssertEqual(store.activeMode, .normal)
    }

    func testSavedDefaultIsUsedWhenNothingWasPickedThisSession() {
        defaults.set("stretch", forKey: VideoViewModeStore.defaultModeKey)
        let store = VideoViewModeStore(defaults: defaults)
        XCTAssertEqual(store.activeMode, .stretch)
    }

    func testUnknownStoredValueFallsBackToNormal() {
        defaults.set("nonLinearStretch", forKey: VideoViewModeStore.defaultModeKey)
        XCTAssertEqual(VideoViewModeStore(defaults: defaults).defaultMode, .normal)
    }

    func testSessionPickOverridesDefaultWithoutSavingIt() {
        defaults.set("stretch", forKey: VideoViewModeStore.defaultModeKey)
        let store = VideoViewModeStore(defaults: defaults)
        store.choose(.zoom)
        XCTAssertEqual(store.activeMode, .zoom)
        XCTAssertEqual(store.defaultMode, .stretch)
        XCTAssertEqual(defaults.string(forKey: VideoViewModeStore.defaultModeKey), "stretch")
    }

    /// A session pick does not outlive the app: a new store (a relaunch)
    /// opens in the saved default again.
    func testSessionPickIsNotPersisted() {
        VideoViewModeStore(defaults: defaults).choose(.zoom)
        XCTAssertEqual(VideoViewModeStore(defaults: defaults).activeMode, .normal)
    }

    func testUseForAllVideosSavesTheActiveMode() {
        let store = VideoViewModeStore(defaults: defaults)
        store.choose(.zoom)
        store.useActiveModeForAllVideos()
        XCTAssertEqual(store.defaultMode, .zoom)
        XCTAssertEqual(store.activeMode, .zoom)
        XCTAssertEqual(VideoViewModeStore(defaults: defaults).activeMode, .zoom)
    }

    /// Choosing a default in Settings is the newer decision, so it must take
    /// effect for the next video rather than sit behind an earlier pick.
    func testSettingDefaultReplacesTheSessionPick() {
        let store = VideoViewModeStore(defaults: defaults)
        store.choose(.stretch)
        store.setDefault(.normal)
        XCTAssertNil(store.sessionMode)
        XCTAssertEqual(store.activeMode, .normal)
    }

    func testGravityPerMode() {
        XCTAssertEqual(VideoViewMode.normal.videoGravity, .resizeAspect)
        XCTAssertEqual(VideoViewMode.zoom.videoGravity, .resizeAspectFill)
        XCTAssertEqual(VideoViewMode.stretch.videoGravity, .resize)
    }

    /// The names are shared with the Roku and Android clients.
    func testNamesMatchTheOtherClients() {
        XCTAssertEqual(VideoViewMode.allCases.map(\.displayName), ["Normal", "Zoom", "Stretch"])
    }

    func testEverySymbolExists() {
        for mode in VideoViewMode.allCases {
            XCTAssertNotNil(UIImage(systemName: mode.systemImage), mode.displayName)
        }
        XCTAssertNotNil(UIImage(systemName: "aspectratio"))
    }
}

@MainActor
final class ViewModeMenuTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ViewModeMenuTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func actions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { $0 as? UIAction }
    }

    func testMenuNamesAndChecksTheActiveMode() {
        let store = VideoViewModeStore(defaults: defaults)
        store.choose(.zoom)
        let menu = TVPlayerView.viewModeMenu(store: store)
        XCTAssertEqual(menu.title, "View Mode")
        XCTAssertEqual(menu.subtitle, "Zoom")
        let items = actions(in: menu)
        XCTAssertEqual(items.map(\.title), ["Normal", "Zoom", "Stretch", "Use for All Videos"])
        XCTAssertEqual(items.map(\.state), [.off, .on, .off, .off])
        XCTAssertEqual(items.last?.subtitle, "Default: Normal")
    }

    func testUseForAllIsCheckedOnceTheActiveModeIsTheDefault() {
        let store = VideoViewModeStore(defaults: defaults)
        store.setDefault(.stretch)
        let items = actions(in: TVPlayerView.viewModeMenu(store: store))
        XCTAssertEqual(items.map(\.state), [.off, .off, .on, .on])
    }
}
