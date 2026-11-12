import XCTest
@testable import SashimiMobile

/// iPad/Mac Home & Side Menu is one list (#841): Lists and the libraries Home
/// has no row for drag among Home's rows, and the rail follows. Home stays
/// first and Settings last; Search is an entry like the rest (A1 parity).
@MainActor
final class IPadSideMenuOrderTests: XCTestCase {
    private let server = "side-menu-order-test"

    override func tearDown() async throws {
        await MainActor.run {
            ["homeRowOrder.\(server)", "\(HomeRowSettings.sideMenuOrderKey).\(server)", "homeRowOrder.other-\(server)",
             "\(HomeRowSettings.sideMenuOrderKey).other-\(server)"]
                .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
    }

    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
        JellyfinLibrary(id: "boxsets", name: "Collections", collectionType: "boxsets", imageTags: nil),
        JellyfinLibrary(id: "playlists", name: "Playlists", collectionType: "playlists", imageTags: nil)
    ]

    private var homeRows: [HomeRowConfig] {
        [
            HomeRowConfig(type: .builtIn(.continueWatching), isEnabled: true),
            HomeRowConfig(type: .builtIn(.channels), isEnabled: true),
            HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: true),
            HomeRowConfig(type: .list(id: "abc", title: "From Chad: Halloween"), isEnabled: true)
        ]
    }

    private func names(_ items: [SidebarSelection]) -> [String] { items.map(\.displayName) }

    /// A fresh settings state for a throwaway server; restores the real one after.
    private func withSettings(_ body: (HomeRowSettings) throws -> Void) rethrows {
        let settings = HomeRowSettings.shared
        let original = settings.serverID
        defer { settings.use(serverID: original) }
        settings.use(serverID: server)
        settings.rows = homeRows
        settings.saveRows()
        try body(settings)
    }

    func testWithNothingSavedTheRailOnlyGainsSearchFirst() {
        withSettings { settings in
            XCTAssertNil(settings.sideMenuOrder)
            XCTAssertEqual(
                names(SidebarSelection.railItems(rowConfigs: settings.rows, libraries: libraries, savedOrder: nil)),
                ["Home", "Search", "SashimiTV", "Movies", "Collections", "Playlists", "Lists", "Settings"]
            )
        }
    }

    func testDraggingListsAndPlaylistsMovesThemInTheRail() {
        withSettings { settings in
            var entries = settings.sideMenuEntries(libraryIds: libraries.map(\.id))
            // Lists under SashimiTV, Playlists to the very top.
            let lists = entries.firstIndex(of: .menuOnly(.lists)) ?? 0
            let channels = entries.firstIndex(of: .row(HomeRowType.channels.rawValue)) ?? 0
            entries = SideMenuOrder.moving(entries, from: [lists], to: channels + 1)
            let playlists = entries.firstIndex(of: .menuOnly(.library("playlists"))) ?? 0
            entries = SideMenuOrder.moving(entries, from: [playlists], to: 0)
            settings.applySideMenuOrder(entries)

            XCTAssertEqual(
                names(SidebarSelection.railItems(
                    rowConfigs: settings.rows, libraries: libraries, savedOrder: settings.sideMenuOrder
                )),
                ["Home", "Playlists", "Search", "SashimiTV", "Lists", "Movies", "Collections", "Settings"]
            )
            XCTAssertEqual(settings.rows, homeRows, "Home (and iPhone's Row Order) never gains the menu-only entries")
        }
    }

    func testDraggingARowStillReordersHome() {
        withSettings { settings in
            let entries = settings.sideMenuEntries(libraryIds: libraries.map(\.id))
            let movies = entries.firstIndex(of: .row("movies")) ?? 0
            settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [movies], to: 0))
            XCTAssertEqual(settings.rows.first?.id, "movies")
        }
    }

    /// Saved per server, like the rows: another server's order is its own.
    func testTheOrderIsSavedPerServer() {
        withSettings { settings in
            let entries = settings.sideMenuEntries(libraryIds: libraries.map(\.id))
            let moved = SideMenuOrder.moving(entries, from: [entries.count - 1], to: 0)
            settings.applySideMenuOrder(moved)

            settings.use(serverID: "other-\(server)")
            XCTAssertNil(settings.sideMenuOrder)

            settings.use(serverID: server)
            settings.loadRows()
            XCTAssertEqual(settings.sideMenuEntries(libraryIds: libraries.map(\.id)), moved)
        }
    }

    /// The hero reads Home's rows only (#836), so it ignores the side-menu order.
    func testTheHeroStillFollowsHomeRows() {
        withSettings { settings in
            settings.toggleRow(at: 2)
            let before = settings.heroHidden(itemLibraryIds: [:])
            let entries = settings.sideMenuEntries(libraryIds: libraries.map(\.id))
            settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [entries.count - 1], to: 0))
            XCTAssertEqual(settings.heroHidden(itemLibraryIds: [:]), before)
            XCTAssertEqual(before.libraryIds, ["movies"])
        }
    }
}
