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
            [.search, .library("movies"), .library("anime"), .finTV, .lists],
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
            [.search, .library("movies"), .lists]
        )
    }

    func testALibraryAddedOnTheServerLaterIsListed() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [library("movies")], libraryIds: ["movies", "new"], hidden: [.library("movies")]),
            [.search, .library("new"), .finTV, .lists]
        )
    }

    func testAHiddenIdTheServerNoLongerHasChangesNothing() {
        XCTAssertEqual(
            RailOrder.destinations(rowOrder: [], libraryIds: ["tv"], hidden: [.library("gone")]),
            [.search, .library("tv"), .finTV, .lists]
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
        let rows = [HomeRowConfig.builtIn(.channels), library("movies")].map(\.sideMenuRow)
        XCTAssertEqual(
            SideMenuOrder.menuOnly(rows: rows, libraryIds: libraries.map(\.id)),
            [.search, .library("collections"), .library("playlists"), .lists]
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
        XCTAssertFalse(RailOrder.destinations(rowOrder: [.lists], libraryIds: ["tv"], hidden: [.lists]).contains(.lists))
    }

    func testOnlyReachableFromSearchWhenHiddenFromBoth() {
        XCTAssertEqual(RailOrder.reachabilityNote(isOnHome: false, isInSideMenu: false), "Only reachable from Search")
        XCTAssertNil(RailOrder.reachabilityNote(isOnHome: true, isInSideMenu: false))
        XCTAssertNil(RailOrder.reachabilityNote(isOnHome: false, isInSideMenu: true))
    }
}
