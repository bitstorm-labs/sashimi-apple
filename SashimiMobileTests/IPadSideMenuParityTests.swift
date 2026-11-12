import XCTest
@testable import SashimiMobile

/// The iPad/Mac rail follows the one side-menu model (parity audit A1): Home
/// first, Settings last, and Search and Downloads are ordinary entries of the
/// Home & Side Menu list. Default order: Search, Watchlist, SashimiTV,
/// libraries, Lists, Requests, Dashboard, Downloads.
@MainActor
final class IPadSideMenuParityTests: XCTestCase {
    private let server = "side-menu-parity-test"

    override func tearDown() async throws {
        await MainActor.run {
            ["homeRowOrder.\(server)", "\(HomeRowSettings.sideMenuOrderKey).\(server)"]
                .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
    }

    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
        JellyfinLibrary(id: "tv", name: "TV Shows", collectionType: "tvshows", imageTags: nil),
        JellyfinLibrary(id: "boxsets", name: "Collections", collectionType: "boxsets", imageTags: nil)
    ]

    private let everything: [RailOrder.Destination] = [.watchlist, .requests, .dashboard, .downloads]

    /// An install from before: Requests straight after Continue Watching.
    private let oldRows: [HomeRowConfig] = [
        HomeRowConfig(type: .builtIn(.continueWatching), isEnabled: true),
        HomeRowConfig(type: .builtIn(.requests), isEnabled: true),
        HomeRowConfig(type: .builtIn(.channels), isEnabled: true),
        HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: true),
        HomeRowConfig(type: .library(id: "tv", name: "TV Shows"), isEnabled: true)
    ]

    private func names(
        _ rows: [HomeRowConfig],
        saved: [String]? = nil,
        hidden: Set<RailOrder.Destination> = []
    ) -> [String] {
        SidebarSelection.railItems(
            rowConfigs: rows, libraries: libraries, hidden: hidden, savedOrder: saved, available: everything
        ).map(\.displayName)
    }

    /// A fresh settings state for a throwaway server; restores the real one after.
    private func withFreshSettings(_ body: (HomeRowSettings) throws -> Void) rethrows {
        let settings = HomeRowSettings.shared
        let original = settings.serverID
        defer { settings.use(serverID: original) }
        UserDefaults.standard.removeObject(forKey: "homeRowOrder.\(server)")
        UserDefaults.standard.removeObject(forKey: "\(HomeRowSettings.sideMenuOrderKey).\(server)")
        settings.use(serverID: server)
        try body(settings)
    }

    func testAFreshInstallListsTheSharedDefaultOrder() {
        withFreshSettings { settings in
            // A legacy unscoped list would seed it; this server must start clean.
            settings.rows = HomeRowSettings.defaultRows
            settings.updateLibraries(libraries)
            XCTAssertEqual(
                names(settings.rows),
                ["Home", "Search", "Watchlist", "SashimiTV", "Movies", "TV Shows", "Collections", "Lists",
                 "Requests", "Dashboard", "Downloads", "Settings"]
            )
        }
    }

    func testAnOrderSavedBeforeSearchKeepsItsRelativeOrder() {
        // The Watchlist was dragged under Movies, Lists to the top.
        let saved = ["menu:lists", "continue_watching", "requests", "channels", "movies", "menu:watchlist", "tv",
                     "menu:library:boxsets", "menu:dashboard"]
        XCTAssertEqual(
            names(oldRows, saved: saved),
            ["Home", "Search", "Watchlist", "Lists", "Requests", "SashimiTV", "Movies", "TV Shows", "Collections",
             "Dashboard", "Downloads", "Settings"]
        )
    }

    func testSearchAndDownloadsMoveAndStayMoved() {
        withFreshSettings { settings in
            settings.rows = oldRows
            settings.saveRows()
            var entries = settings.sideMenuEntries(libraryIds: libraries.map(\.id), available: everything)
            XCTAssertEqual(entries.first, .menuOnly(.search))
            XCTAssertEqual(entries.last, .menuOnly(.downloads))

            // Downloads to the top, Search to the end.
            entries = SideMenuOrder.moving(entries, from: [entries.count - 1], to: 0)
            entries = SideMenuOrder.moving(entries, from: [1], to: entries.count)
            settings.applySideMenuOrder(entries)

            settings.loadRows()
            XCTAssertEqual(
                names(settings.rows, saved: settings.sideMenuOrder),
                ["Home", "Downloads", "Watchlist", "Requests", "SashimiTV", "Movies", "TV Shows", "Collections",
                 "Lists", "Dashboard", "Search", "Settings"]
            )
        }
    }

    func testSearchAndDownloadsCanBeHidden() {
        XCTAssertEqual(
            names(oldRows, hidden: [.search, .downloads]),
            ["Home", "Watchlist", "Requests", "SashimiTV", "Movies", "TV Shows", "Collections", "Lists", "Dashboard",
             "Settings"]
        )
        XCTAssertEqual(SidebarSelection.search.railDestination, .search)
        XCTAssertEqual(SidebarSelection.downloads.railDestination, .downloads)
        XCTAssertNil(SidebarSelection.home.railDestination)
        XCTAssertNil(SidebarSelection.settings.railDestination)
    }

    /// Search, the Watchlist and Downloads now share the rail with every
    /// library: in landscape the rows tighten so Settings stays clear of the
    /// account avatar (13 rows in ~630pt on an 11-inch iPad).
    func testRowsTightenToFitALandscapeRail() {
        XCTAssertEqual(SidebarRailMetrics.rowVerticalPadding(rows: 8, height: 900), 11, "room to spare: unchanged")
        let padding = SidebarRailMetrics.rowVerticalPadding(rows: 13, height: 630)
        XCTAssertLessThan(padding, 11)
        XCTAssertLessThanOrEqual(13 * (28 + 2 * padding + 4), 630)
        XCTAssertEqual(SidebarRailMetrics.rowVerticalPadding(rows: 40, height: 630), 4, "never below 4pt; it scrolls")
    }
}
