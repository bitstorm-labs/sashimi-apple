import XCTest
@testable import Sashimi

/// Which destinations the side menu lists (#753): its own setting, separate
/// from Home's.
@MainActor
final class SideMenuVisibilityTests: XCTestCase {
    private let suite = "SideMenuVisibilityTests"
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func library(_ id: String, home: Bool = true) -> HomeRowConfig {
        .library(id: id, name: "Library \(id)", visible: home)
    }

    func testAHiddenDestinationLeavesTheMenuWhateverHomeShows() {
        let configs = [library("movies"), library("anime", home: false), library("kids")]
        XCTAssertEqual(
            RailOrder.destinations(
                rowConfigs: configs, libraryIds: ["movies", "anime", "kids"], hidden: [.library("kids")]
            ),
            [.library("movies"), .library("anime"), .finTV],
            "hidden from Home only: still listed; hidden from the menu: dropped"
        )
    }

    func testSashimiTVAndMenuOnlyLibrariesCanBeHidden() {
        XCTAssertEqual(
            RailOrder.destinations(
                rowConfigs: [.builtIn(.channels), library("movies")],
                libraryIds: ["movies", "playlists"],
                hidden: [.finTV, .library("playlists")]
            ),
            [.library("movies")]
        )
    }

    func testALibraryAddedOnTheServerLaterIsListed() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [library("movies")], libraryIds: ["movies", "new"], hidden: [.library("movies")]),
            [.library("new"), .finTV]
        )
    }

    func testAHiddenIdTheServerNoLongerHasChangesNothing() {
        XCTAssertEqual(
            RailOrder.destinations(rowOrder: [], libraryIds: ["tv"], hidden: [.library("gone")]),
            [.library("tv"), .finTV]
        )
    }

    func testOnlyHomeRowsThatAreDestinationsGetASwitch() {
        XCTAssertNil(HomeRowConfig.builtIn(.hero).railDestination)
        XCTAssertNil(HomeRowConfig.builtIn(.continueWatching).railDestination)
        XCTAssertEqual(HomeRowConfig.builtIn(.channels).railDestination, .finTV)
        XCTAssertEqual(library("x").railDestination, .library("x"))
    }

    func testLibrariesWithoutAHomeRowGetTheirOwnSwitch() {
        let libraries = ["movies", "collections", "playlists"].map {
            JellyfinLibrary(id: $0, name: $0, collectionType: nil, imageTags: nil)
        }
        XCTAssertEqual(
            RailOrder.menuOnlyLibraries(libraries, homeDestinations: [.library("movies"), .finTV]).map(\.id),
            ["collections", "playlists"]
        )
    }

    func testTheStoreStartsWithEverythingShownAndRemembersWhatWasHidden() {
        let store = SideMenuSettings(defaults: defaults)
        XCTAssertTrue(store.isShown(.finTV))
        store.setShown(false, for: .library("kids"))
        store.toggle(.finTV)

        let reloaded = SideMenuSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hidden, [.library("kids"), .finTV])
        reloaded.toggle(.finTV)
        XCTAssertEqual(SideMenuSettings(defaults: defaults).hidden, [.library("kids")])
    }

    /// Lists is a side-menu destination of its own (shared lists), hideable
    /// like a library, and never a Home row.
    func testListsCanBeHiddenAndIsRemembered() {
        let store = SideMenuSettings(defaults: defaults)
        XCTAssertTrue(store.isShown(.lists))
        store.toggle(.lists)
        XCTAssertEqual(SideMenuSettings(defaults: defaults).hidden, [.lists])
        XCTAssertFalse(RailOrder.destinations(rowOrder: [.lists], libraryIds: ["tv"]).contains(.lists))
    }

    func testOnlyReachableFromSearchWhenHiddenFromBoth() {
        XCTAssertEqual(RailOrder.reachabilityNote(isOnHome: false, isInSideMenu: false), "Only reachable from Search")
        XCTAssertNil(RailOrder.reachabilityNote(isOnHome: true, isInSideMenu: false))
        XCTAssertNil(RailOrder.reachabilityNote(isOnHome: false, isInSideMenu: true))
    }
}
