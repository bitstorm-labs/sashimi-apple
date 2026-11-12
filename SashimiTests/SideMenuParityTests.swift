import XCTest
@testable import Sashimi

/// One side-menu model on every Sashimi app (parity audit A1): Home first,
/// Settings last, and everything between is the one list Settings › Home &
/// Side Menu orders, Search and the Watchlist included. The same default
/// order everywhere: Search, Watchlist, SashimiTV, libraries, Lists,
/// Requests, Dashboard. Orders saved before Search was an entry keep their
/// relative order and gain Search at the top with the Watchlist under it.
@MainActor
final class SideMenuParityTests: XCTestCase {
    private let suite = "SideMenuParityTests"
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

    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
        JellyfinLibrary(id: "tv", name: "TV Shows", collectionType: "tvshows", imageTags: nil),
        JellyfinLibrary(id: "boxsets", name: "Collections", collectionType: "boxsets", imageTags: nil)
    ]

    private let everything: [RailOrder.Destination] = [.watchlist, .requests, .dashboard]

    /// The rows an install from before this change has: Requests straight
    /// after Continue Watching, where #861 put it.
    private let oldRows: [HomeRowConfig] = [
        .builtIn(.hero),
        .builtIn(.continueWatching),
        .builtIn(.requests),
        .builtIn(.channels),
        .library(id: "movies", name: "Movies"),
        .library(id: "tv", name: "TV Shows")
    ]

    private func titles(
        _ rows: [HomeRowConfig],
        saved: [String]? = nil,
        hidden: Set<RailOrder.Destination> = [],
        available: [RailOrder.Destination]? = nil
    ) -> [String] {
        MainTabView.navRows(
            rowConfigs: rows,
            libraries: libraries,
            hidden: hidden,
            savedOrder: saved,
            available: available ?? everything
        ).map(\.title)
    }

    // MARK: Default order

    func testAFreshInstallListsTheSharedDefaultOrder() {
        let settings = HomeScreenSettings(defaults: defaults)
        settings.updateWithLibraries(libraries)

        XCTAssertEqual(
            titles(settings.rowConfigs),
            ["Home", "Search", "Watchlist", "SashimiTV", "Movies", "TV Shows", "Collections", "Lists",
             "Requests", "Dashboard", "Settings"]
        )
    }

    func testAFreshInstallPutsTheRequestsRowAfterTheLibraries() {
        let settings = HomeScreenSettings(defaults: defaults)
        settings.updateWithLibraries(libraries)

        XCTAssertEqual(
            settings.rowConfigs.map(\.id),
            ["hero", "continueWatching", "channels", "library_movies", "library_tv", "library_boxsets", "requests"]
        )
    }

    func testSettingsListsSearchAndTheWatchlistFirst() {
        let entries = SideMenuOrder.entries(
            rows: oldRows.map(\.sideMenuRow),
            libraryIds: libraries.map(\.id),
            saved: nil,
            available: everything
        )
        XCTAssertEqual(Array(entries.prefix(2)), [.menuOnly(.search), .menuOnly(.watchlist)])
    }

    func testOnlyHomeAndSettingsArePinned() {
        let rows = titles(oldRows, hidden: [.search, .watchlist, .finTV, .lists, .requests, .dashboard,
                                            .library("movies"), .library("tv"), .library("boxsets")])
        XCTAssertEqual(rows, ["Home", "Settings"])
    }

    // MARK: Migration

    func testAnOrderSavedBeforeSearchKeepsItsRelativeOrder() {
        // The Watchlist was moved under Movies, Lists to the top.
        let saved = ["menu:lists", "hero", "continueWatching", "requests", "channels", "library_movies",
                     "menu:watchlist", "library_tv", "menu:library:boxsets", "menu:dashboard"]

        XCTAssertEqual(
            titles(oldRows, saved: saved),
            ["Home", "Search", "Watchlist", "Lists", "Requests", "SashimiTV", "Movies", "TV Shows", "Collections",
             "Dashboard", "Settings"]
        )
    }

    func testAnInstallThatNeverMovedAnythingGainsSearchAndKeepsItsRows() {
        XCTAssertEqual(
            titles(oldRows),
            ["Home", "Search", "Watchlist", "Requests", "SashimiTV", "Movies", "TV Shows", "Collections", "Lists",
             "Dashboard", "Settings"]
        )
    }

    // MARK: Moving Search and the Watchlist

    func testSearchAndTheWatchlistMoveLikeAnyOtherEntry() throws {
        let settings = HomeScreenSettings(defaults: defaults)
        settings.rowConfigs = oldRows
        var entries = settings.sideMenuEntries(libraryIds: libraries.map(\.id), available: everything)
        XCTAssertEqual(entries.first, .menuOnly(.search))

        // Search to the very end, the Watchlist under Movies.
        entries = SideMenuOrder.moving(entries, from: [0], to: entries.count)
        let watchlist = try XCTUnwrap(entries.firstIndex(of: .menuOnly(.watchlist)))
        let movies = try XCTUnwrap(entries.firstIndex(of: .row("library_movies")))
        entries = SideMenuOrder.moving(entries, from: [watchlist], to: movies + 1)
        settings.applySideMenuOrder(entries)

        let reloaded = HomeScreenSettings(defaults: defaults)
        reloaded.rowConfigs = settings.rowConfigs
        let rail = titles(reloaded.rowConfigs, saved: reloaded.sideMenuOrder)
        XCTAssertEqual(
            rail,
            ["Home", "Requests", "SashimiTV", "Movies", "Watchlist", "TV Shows", "Collections", "Lists", "Dashboard",
             "Search", "Settings"]
        )
    }

    // MARK: Hiding

    func testSearchCanBeHiddenAndComesBack() {
        let side = SideMenuSettings(defaults: defaults)
        side.setShown(false, for: .search)
        XCTAssertFalse(titles(oldRows, hidden: side.hidden).contains("Search"))

        let reloaded = SideMenuSettings(defaults: defaults)
        XCTAssertEqual(reloaded.hidden, [.search])
        reloaded.setShown(true, for: .search)
        XCTAssertEqual(titles(oldRows, hidden: reloaded.hidden)[1], "Search")
    }

    func testHidingTheWatchlistLeavesSearchFirst() {
        XCTAssertEqual(Array(titles(oldRows, hidden: [.watchlist]).prefix(3)), ["Home", "Search", "Requests"])
    }

    func testTheSharedIdsAreStable() {
        XCTAssertEqual(RailOrder.Destination.search.storageKey, "search")
        XCTAssertEqual(RailOrder.Destination.downloads.storageKey, "downloads")
        XCTAssertEqual(RailOrder.Destination(storageKey: "search"), .search)
        XCTAssertEqual(RailOrder.Destination(storageKey: "downloads"), .downloads)
    }
}
