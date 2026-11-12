import XCTest
@testable import SashimiMobile

/// The Watchlist in the iPad/Mac side menu (#894): straight under Search
/// until moved, there while the server has a Watchlist, hideable, and
/// numbered by the menu bar like every other rail item.
@MainActor
final class IPadWatchlistRailTests: XCTestCase {
    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil)
    ]
    private let rows = [
        HomeRowConfig(type: .builtIn(.channels), isEnabled: true),
        HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: true)
    ]
    private let movies = SidebarSelection.library(id: "movies", name: "Movies", collectionType: "movies")

    func testItFollowsSearch() {
        XCTAssertEqual(
            SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, available: [.watchlist, .requests]),
            [.home, .search, .watchlist, .finTV, movies, .lists, .requests, .settings]
        )
    }

    func testWithoutTheServersWatchlistItIsNotThere() {
        XCTAssertFalse(SidebarSelection.railItems(rowConfigs: rows, libraries: libraries).contains(.watchlist))
    }

    func testHiddenItLeavesTheRail() {
        let items = SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, hidden: [.watchlist], available: [.watchlist])
        XCTAssertFalse(items.contains(.watchlist))
    }

    func testASavedOrderFromBeforeItPutsItUnderSearch() {
        let saved = ["menu:lists", "channels", "library_movies"]
        XCTAssertEqual(
            SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, savedOrder: saved, available: [.watchlist]),
            [.home, .search, .watchlist, .lists, .finTV, movies, .settings]
        )
    }

    func testItIsADestinationThatNeedsTheServer() {
        XCTAssertEqual(SidebarSelection.watchlist.railDestination, .watchlist)
        XCTAssertFalse(SidebarSelection.watchlist.isAvailableOffline)
        XCTAssertEqual(SidebarSelection.watchlist.icon, "bookmark")
        XCTAssertEqual(SidebarSelection.watchlist.helpLabel, "Watchlist")
    }
}
