import XCTest
@testable import SashimiMobile

/// The iPad/Mac side menu drops what the user hid from it (#753); Home,
/// Search, Downloads and Settings are always there.
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
            [.home, .library(id: "movies", name: "Movies", collectionType: "movies"), .search, .downloads, .settings]
        )
    }

    func testOnlyLibrariesAndSashimiTVCanBeHidden() {
        XCTAssertNil(SidebarSelection.home.railDestination)
        XCTAssertNil(SidebarSelection.search.railDestination)
        XCTAssertNil(SidebarSelection.downloads.railDestination)
        XCTAssertNil(SidebarSelection.settings.railDestination)
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
