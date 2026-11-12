import XCTest
@testable import SashimiMobile

/// The iPad/Mac side menu drops what the user hid from it (#753); Home and
/// Settings are always there (A1 parity: Search and Downloads can be hidden).
final class IPadSideMenuVisibilityTests: XCTestCase {
    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
        JellyfinLibrary(id: "kids", name: "Kids", collectionType: "movies", imageTags: nil)
    ]

    func testHiddenEntriesLeaveTheMenuButTheFixedOnesStay() {
        let rows = [
            HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: true),
            HomeRowConfig(type: .library(id: "kids", name: "Kids"), isEnabled: true),
            HomeRowConfig(type: .builtIn(.channels), isEnabled: false)
        ]
        XCTAssertEqual(
            SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, hidden: [.library("kids"), .finTV]),
            [.home, .search, .library(id: "movies", name: "Movies", collectionType: "movies"), .lists, .settings]
        )
    }

    /// Lists sits after the libraries and can be hidden like them.
    func testListsFollowsTheLibrariesAndCanBeHidden() {
        let libraries = [JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil)]
        let rows = [HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: true)]
        XCTAssertEqual(SidebarSelection.lists.railDestination, .lists)
        XCTAssertEqual(
            SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, hidden: [.finTV]),
            [.home, .search, .library(id: "movies", name: "Movies", collectionType: "movies"), .lists, .settings]
        )
        XCTAssertFalse(SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, hidden: [.lists]).contains(.lists))
    }

    func testOnlyHomeAndSettingsCannotBeHidden() {
        XCTAssertNil(SidebarSelection.home.railDestination)
        XCTAssertNil(SidebarSelection.settings.railDestination)
        XCTAssertEqual(SidebarSelection.search.railDestination, .search)
        XCTAssertEqual(SidebarSelection.downloads.railDestination, .downloads)
        XCTAssertEqual(SidebarSelection.finTV.railDestination, .finTV)
        XCTAssertEqual(
            SidebarSelection.library(id: "m", name: "Movies", collectionType: nil).railDestination, .library("m")
        )
    }

    func testHomeRowsMapToTheirMenuEntries() {
        XCTAssertNil(HomeRowConfig(type: .builtIn(.continueWatching), isEnabled: true).railDestination)
        XCTAssertEqual(HomeRowConfig(type: .builtIn(.channels), isEnabled: true).railDestination, .finTV)
    }
}
