import XCTest
@testable import SashimiMobile

/// Requests and Dashboard in the iPad/Mac side menu (#845): after Lists until
/// moved, only while the account allows them, hideable like Lists, and
/// numbered by the menu bar like every other rail item.
@MainActor
final class IPadRequestsDashboardRailTests: XCTestCase {
    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil)
    ]
    private let rows = [
        HomeRowConfig(type: .builtIn(.channels), isEnabled: true),
        HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: true)
    ]
    private let movies = SidebarSelection.library(id: "movies", name: "Movies", collectionType: "movies")

    func testTheyFollowListsBeforeSearchDownloadsAndSettings() {
        XCTAssertEqual(
            SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, available: [.requests, .dashboard]),
            [.home, .finTV, movies, .lists, .requests, .dashboard, .search, .downloads, .settings]
        )
    }

    func testWithoutAnAccountOrAdminTheyAreNotThere() {
        let items = SidebarSelection.railItems(rowConfigs: rows, libraries: libraries)
        XCTAssertFalse(items.contains(.requests))
        XCTAssertFalse(items.contains(.dashboard))
        XCTAssertEqual(
            SidebarSelection.railItems(
                rowConfigs: rows,
                libraries: libraries,
                available: RailOrder.conditionalDestinations(seerr: .notConfigured, canViewDashboard: true)
            ),
            [.home, .finTV, movies, .lists, .dashboard, .search, .downloads, .settings]
        )
    }

    func testHiddenTheyLeaveTheRail() {
        let items = SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, hidden: [.requests], available: [.requests, .dashboard])
        XCTAssertFalse(items.contains(.requests))
        XCTAssertTrue(items.contains(.dashboard))
    }

    func testTheyAreDestinationsThatNeedTheServer() {
        XCTAssertEqual(SidebarSelection.requests.railDestination, .requests)
        XCTAssertEqual(SidebarSelection.dashboard.railDestination, .dashboard)
        XCTAssertFalse(SidebarSelection.requests.isAvailableOffline)
        XCTAssertFalse(SidebarSelection.dashboard.isAvailableOffline)
        XCTAssertEqual(SidebarSelection.requests.icon, "tray.and.arrow.down")
        XCTAssertEqual(SidebarSelection.dashboard.helpLabel, "Dashboard")
    }

    func testAMovedRequestsEntryLeadsTheRail() {
        let start = SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: ["movies"], saved: nil, available: [.requests])
        let requests = start.firstIndex(of: .menuOnly(.requests)) ?? 0
        let saved = SideMenuOrder.savedKeys(SideMenuOrder.moving(start, from: [requests], to: 0))
        XCTAssertEqual(
            SidebarSelection.railItems(rowConfigs: rows, libraries: libraries, savedOrder: saved, available: [.requests]),
            [.home, .requests, .finTV, movies, .lists, .search, .downloads, .settings]
        )
    }
}
