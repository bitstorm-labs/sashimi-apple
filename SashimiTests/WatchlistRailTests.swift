import XCTest
@testable import Sashimi

/// The Watchlist in the side menu (#894): a menu-only destination like Lists,
/// directly under Search until moved, there while the server has a Watchlist,
/// and saved orders from before it keep everything else where it was. Search
/// is an entry of the same list (A1 parity), so both lead it by default.
@MainActor
final class WatchlistRailTests: XCTestCase {
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

    // MARK: Availability

    func testTheWatchlistComesWithTheServersWatchlistAndLeadsTheOthers() {
        let user = SeerrUser(id: 45, displayName: "test")
        XCTAssertEqual(
            RailOrder.conditionalDestinations(seerr: .notConfigured, canViewDashboard: false, hasWatchlist: true),
            [.watchlist]
        )
        XCTAssertEqual(
            RailOrder.conditionalDestinations(seerr: .signedIn(user), canViewDashboard: true, hasWatchlist: true),
            [.watchlist, .requests, .dashboard]
        )
        XCTAssertEqual(RailOrder.conditionalDestinations(seerr: .notConfigured, canViewDashboard: false, hasWatchlist: false), [])
        XCTAssertTrue(RailOrder.isConditional(.watchlist))
    }

    /// Shown until the server says it has no Watchlist, so a launch never
    /// waits on the answer to draw the menu.
    func testOnlyAServerWithoutTheListsPluginTakesItAway() {
        XCTAssertTrue(RailOrder.hasWatchlist(.unknown))
        XCTAssertTrue(RailOrder.hasWatchlist(.available))
        XCTAssertFalse(RailOrder.hasWatchlist(.unavailable))
    }

    func testStorageKeysRoundTrip() {
        XCTAssertEqual(RailOrder.Destination.watchlist.storageKey, "watchlist")
        XCTAssertEqual(RailOrder.Destination(storageKey: "watchlist"), .watchlist)
        XCTAssertEqual(SideMenuOrder.Entry.menuOnly(.watchlist).storageKey, "menu:watchlist")
        XCTAssertEqual(SideMenuOrder.Entry(storageKey: "menu:watchlist"), .menuOnly(.watchlist))
    }

    // MARK: Default place

    func testWithNothingSavedItSitsDirectlyUnderSearch() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, available: [.watchlist]),
            [.search, .watchlist, .finTV, .library("movies"), .library("boxsets"), .lists]
        )
        let rail = MainTabView.navRows(rowConfigs: rows, libraries: libraries, hidden: [], available: [.watchlist])
        XCTAssertEqual(rail.map(\.title), ["Home", "Search", "Watchlist", "SashimiTV", "Movies", "Collections", "Lists", "Settings"])
        XCTAssertEqual(rail.first { $0.id == .watchlist }?.icon, "bookmark")
        XCTAssertEqual(
            Array(SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: nil, available: [.watchlist])
                .prefix(2)),
            [.menuOnly(.search), .menuOnly(.watchlist)],
            "Settings lists it under Search too"
        )
    }

    /// An order saved before the Watchlist existed (Lists moved to the top,
    /// Requests moved under SashimiTV): the Watchlist goes under Search and
    /// nothing else moves.
    func testASavedOrderFromBeforeItGetsItUnderSearchAndKeepsTheRest() {
        let saved = ["menu:lists", "hero", "channels", "menu:requests", "library_movies", "menu:library:boxsets"]
        let available: [RailOrder.Destination] = [.requests]
        let before = RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved, available: available)
        let after = RailOrder.destinations(
            rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved, available: [.watchlist] + available
        )
        XCTAssertEqual(before, [.search, .lists, .finTV, .requests, .library("movies"), .library("boxsets")])
        XCTAssertEqual(after, [.search, .watchlist] + before.dropFirst())

        let entries = SideMenuOrder.entries(
            rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: saved, available: [.watchlist] + available
        )
        XCTAssertEqual(Array(entries.prefix(2)), [.menuOnly(.search), .menuOnly(.watchlist)])
        XCTAssertEqual(entries.filter { $0 != .menuOnly(.watchlist) }, SideMenuOrder.entries(
            rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: saved, available: available
        ))
    }

    // MARK: Moving and hiding

    func testMovedItStaysPutAndTheRailFollows() {
        let start = SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: nil, available: [.watchlist])
        let watchlist = start.firstIndex(of: .menuOnly(.watchlist)) ?? 0
        let movies = start.firstIndex(of: .row("library_movies")) ?? 0
        let saved = SideMenuOrder.savedKeys(SideMenuOrder.moving(start, from: [watchlist], to: movies + 1))

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved, available: [.watchlist]),
            [.search, .finTV, .library("movies"), .watchlist, .library("boxsets"), .lists]
        )
        // A server without the plugin leaves the place saved for the next one.
        XCTAssertFalse(RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved).contains(.watchlist))
    }

    func testHiddenItLeavesTheRailAndStaysReachableFromLists() {
        let names = MainTabView.navRows(rowConfigs: rows, libraries: libraries, hidden: [.watchlist], available: [.watchlist])
            .map(\.title)
        XCTAssertFalse(names.contains("Watchlist"))
        XCTAssertNil(
            RailOrder.reachabilityNote(for: .watchlist, isOnHome: false, isInSideMenu: false),
            "Lists still opens it, so it is never only reachable from Search"
        )
    }

    func testUnavailableItIsNotListedAnywhere() {
        XCTAssertFalse(MainTabView.navRows(rowConfigs: rows, libraries: libraries, hidden: []).contains { $0.id == .watchlist })
        XCTAssertFalse(
            SideMenuOrder.entries(rows: rows.map(\.sideMenuRow), libraryIds: libraryIds, saved: nil).contains(.menuOnly(.watchlist))
        )
    }

    func testTheSettingsListUsesTheSameEntries() {
        let suite = "WatchlistRailTests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HomeScreenSettings(defaults: defaults)
        settings.rowConfigs = rows
        XCTAssertEqual(
            Array(settings.sideMenuEntries(libraryIds: libraryIds, available: [.watchlist]).prefix(2)),
            [.menuOnly(.search), .menuOnly(.watchlist)]
        )
    }
}
