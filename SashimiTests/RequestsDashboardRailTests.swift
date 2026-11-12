import XCTest
@testable import Sashimi

/// Requests and Dashboard in the side menu (#845): menu-only entries like
/// Lists, listed only while the account allows them, after Lists until moved,
/// and saved orders from before them keep everything where it was.
@MainActor
final class RequestsDashboardRailTests: XCTestCase {
    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
        JellyfinLibrary(id: "boxsets", name: "Collections", collectionType: "boxsets", imageTags: nil)
    ]
    private var libraryIds: [String] { libraries.map(\.id) }
    private let rows: [HomeRowConfig] = [
        .builtIn(.hero),
        .builtIn(.channels),
        .library(id: "movies", name: "Movies")
    ]
    private let both: [RailOrder.Destination] = [.requests, .dashboard]

    // MARK: Availability

    func testRequestsNeedsASeerrAccountAndDashboardAnAdministrator() {
        let user = SeerrUser(id: 45, displayName: "test")
        XCTAssertEqual(RailOrder.conditionalDestinations(seerr: .notConfigured, canViewDashboard: false), [])
        XCTAssertEqual(RailOrder.conditionalDestinations(seerr: .signedIn(user), canViewDashboard: false), [.requests])
        XCTAssertEqual(RailOrder.conditionalDestinations(seerr: .expired, canViewDashboard: false), [.requests],
                       "an expired sign-in keeps the page so it can say so")
        XCTAssertEqual(RailOrder.conditionalDestinations(seerr: .awaitingPlex(code: "K7QF"), canViewDashboard: true), [.dashboard])
        XCTAssertEqual(RailOrder.conditionalDestinations(seerr: .signedIn(user), canViewDashboard: true), [.requests, .dashboard])
    }

    func testStorageKeysRoundTripThroughMenuKeys() {
        for destination in both {
            XCTAssertEqual(RailOrder.Destination(storageKey: destination.storageKey), destination)
            let entry = SideMenuOrder.Entry.menuOnly(destination)
            XCTAssertEqual(SideMenuOrder.Entry(storageKey: entry.storageKey), entry)
        }
        XCTAssertEqual(SideMenuOrder.Entry.menuOnly(.requests).storageKey, "menu:requests")
        XCTAssertEqual(SideMenuOrder.Entry.menuOnly(.dashboard).storageKey, "menu:dashboard")
    }

    // MARK: Default place

    func testWithNothingSavedTheyFollowListsAtTheEnd() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, available: both),
            [.search, .finTV, .library("movies"), .library("boxsets"), .lists, .requests, .dashboard]
        )
        let names = MainTabView.navRows(rowConfigs: rows, libraries: libraries, hidden: [], available: both).map(\.title)
        XCTAssertEqual(names, ["Home", "Search", "SashimiTV", "Movies", "Collections", "Lists", "Requests", "Dashboard", "Settings"])
    }

    func testTheyStayBehindASashimiTVTheRowsHaveNotPlaced() {
        // Rows saved before SashimiTV existed: it still comes before Lists,
        // and Requests and Dashboard after it, as Lists always has.
        let oldRows: [HomeRowConfig] = [.builtIn(.hero), .library(id: "movies", name: "Movies")]
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: oldRows, libraryIds: libraryIds, available: both),
            [.search, .library("movies"), .library("boxsets"), .finTV, .lists, .requests, .dashboard]
        )
    }

    func testUnavailableTheyAreNotListedAnywhere() {
        XCTAssertFalse(RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds).contains(.requests))
        let entries = SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: nil)
        XCTAssertFalse(entries.contains(.menuOnly(.requests)))
        XCTAssertFalse(entries.contains(.menuOnly(.dashboard)))
        XCTAssertFalse(MainTabView.navRows(rowConfigs: rows, libraries: libraries, hidden: []).contains { $0.id == .requests })
    }

    func testASavedOrderFromBeforeThemKeepsEverythingWhereItWas() {
        // Lists moved to the top under #841, then Requests arrives.
        let saved = ["menu:lists", "hero", "channels", "library_movies", "menu:library:boxsets"]
        let before = RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved)
        let after = RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved, available: both)
        XCTAssertEqual(before, [.search, .lists, .finTV, .library("movies"), .library("boxsets")])
        XCTAssertEqual(after, before + [.requests, .dashboard])

        let entries = SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: saved, available: both)
        XCTAssertEqual(entries.suffix(2), [.menuOnly(.requests), .menuOnly(.dashboard)])
    }

    // MARK: Moving and hiding

    func testMovedTheyStayPutAndTheRailFollows() {
        let start = SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: nil, available: both)
        let requests = start.firstIndex(of: .menuOnly(.requests)) ?? 0
        let moved = SideMenuOrder.moving(start, from: [requests], to: 0)
        let saved = SideMenuOrder.savedKeys(moved)

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved, available: both).first,
            .requests
        )
        // Signed out then back in: the saved place is still honoured.
        XCTAssertFalse(RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved).contains(.requests))
        XCTAssertEqual(
            SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: saved, available: both).first,
            .menuOnly(.requests)
        )
    }

    func testHiddenTheyLeaveTheRail() {
        let names = MainTabView.navRows(rowConfigs: rows, libraries: libraries, hidden: [.dashboard], available: both).map(\.title)
        XCTAssertTrue(names.contains("Requests"))
        XCTAssertFalse(names.contains("Dashboard"))
    }

    func testAHiddenDashboardSaysItHasNoOtherWayIn() {
        XCTAssertEqual(
            RailOrder.reachabilityNote(for: .dashboard, isOnHome: false, isInSideMenu: false),
            "Hidden: the Dashboard has no other way in"
        )
        XCTAssertNil(RailOrder.reachabilityNote(for: .dashboard, isOnHome: false, isInSideMenu: true))
        XCTAssertEqual(RailOrder.reachabilityNote(for: .requests, isOnHome: false, isInSideMenu: false), "Only reachable from Search")
    }

    func testTheSettingsListUsesTheSameEntries() {
        let defaults = UserDefaults(suiteName: "RequestsDashboardRailTests") ?? .standard
        defaults.removePersistentDomain(forName: "RequestsDashboardRailTests")
        defer { defaults.removePersistentDomain(forName: "RequestsDashboardRailTests") }
        let settings = HomeScreenSettings(defaults: defaults)
        settings.rowConfigs = rows
        let entries = settings.sideMenuEntries(libraryIds: libraryIds, available: both)
        XCTAssertEqual(entries.suffix(3), [.menuOnly(.lists), .menuOnly(.requests), .menuOnly(.dashboard)])
    }
}
