import SwiftUI
import XCTest
@testable import Sashimi

/// Settings › Home & Side Menu is one list (#841): Lists and the libraries
/// Home has no row for move among Home's rows, and the rail follows.
@MainActor
final class SideMenuOrderTests: XCTestCase {
    private let suite = "SideMenuOrderTests"
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
        JellyfinLibrary(id: "boxsets", name: "Collections", collectionType: "boxsets", imageTags: nil),
        JellyfinLibrary(id: "playlists", name: "Playlists", collectionType: "playlists", imageTags: nil)
    ]

    private var libraryIds: [String] { libraries.map(\.id) }

    /// What Home shows for this server: no row for Collections or Playlists.
    private let homeRows: [HomeRowConfig] = [
        .builtIn(.hero),
        .builtIn(.continueWatching),
        .builtIn(.channels),
        .library(id: "movies", name: "Movies"),
        .library(id: "tv", name: "TV Shows"),
        .list(id: "abc", title: "From Chad: Halloween")
    ]

    private func settings() -> HomeScreenSettings {
        let settings = HomeScreenSettings(defaults: defaults)
        if settings.rowConfigs.isEmpty {
            settings.rowConfigs = homeRows
            settings.saveSettings()
        }
        return settings
    }

    private func railTitles(_ settings: HomeScreenSettings) -> [String] {
        MainTabView.navRows(
            rowConfigs: settings.rowConfigs,
            libraries: libraries,
            hidden: [],
            savedOrder: settings.sideMenuOrder
        ).map(\.title)
    }

    // MARK: - Existing installs

    /// Nothing saved yet: the menu-only entries sit where the rail has always
    /// put them, after the libraries with Lists last.
    func testWithNothingSavedTheRailIsUnchanged() {
        let settings = settings()
        XCTAssertNil(settings.sideMenuOrder)
        XCTAssertEqual(
            railTitles(settings),
            ["Home", "Search", "SashimiTV", "Movies", "TV Shows", "Collections", "Playlists", "Lists", "Settings"]
        )
        XCTAssertEqual(
            settings.sideMenuEntries(libraryIds: libraryIds).suffix(3),
            [.menuOnly(.library("boxsets")), .menuOnly(.library("playlists")), .menuOnly(.lists)],
            "Settings lists them at the end too, ready to be moved"
        )
    }

    // MARK: - Moving

    func testMovingListsUnderSashimiTVMovesItInTheRail() {
        let settings = settings()
        let entries = settings.sideMenuEntries(libraryIds: libraryIds)
        let lists = entries.firstIndex(of: .menuOnly(.lists)) ?? 0
        let channels = entries.firstIndex(of: .row(HomeRowType.channels.rawValue)) ?? 0
        settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [lists], to: channels + 1))

        XCTAssertEqual(
            railTitles(settings),
            ["Home", "Search", "SashimiTV", "Lists", "Movies", "TV Shows", "Collections", "Playlists", "Settings"]
        )
        XCTAssertEqual(settings.rowConfigs, homeRows, "Home's rows neither move nor gain the menu-only entries")
    }

    func testAMenuOnlyLibraryCanMoveAboveTheHomeRows() {
        let settings = settings()
        let entries = settings.sideMenuEntries(libraryIds: libraryIds)
        let playlists = entries.firstIndex(of: .menuOnly(.library("playlists"))) ?? 0
        settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [playlists], to: 0))

        XCTAssertEqual(
            railTitles(settings),
            ["Home", "Search", "Playlists", "SashimiTV", "Movies", "TV Shows", "Collections", "Lists", "Settings"],
            "Home and Search stay first whatever moves"
        )
    }

    /// Moving a row past menu-only entries still reorders Home.
    func testMovingARowReordersHomeAsBefore() {
        let settings = settings()
        let entries = settings.sideMenuEntries(libraryIds: libraryIds)
        let movies = entries.firstIndex(of: .row("library_movies")) ?? 0
        settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [movies], to: entries.count))

        XCTAssertEqual(settings.rowConfigs.last?.id, "library_movies")
        XCTAssertEqual(railTitles(settings).suffix(3), ["Lists", "Movies", "Settings"])
    }

    /// Hiding a Home row still takes its titles out of the hero (#836): the
    /// hero reads Home's rows, which the menu-only entries never join.
    func testTheHeroStillFollowsHomeRows() {
        let settings = settings()
        if let tv = settings.rowConfigs.first(where: { $0.libraryId == "tv" }) {
            settings.toggleVisibility(for: tv)
        }
        let before = settings.heroHidden(itemLibraryIds: ["a": "tv"])
        let entries = settings.sideMenuEntries(libraryIds: libraryIds)
        settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [entries.count - 1], to: 0))

        XCTAssertEqual(settings.heroHidden(itemLibraryIds: ["a": "tv"]), before)
        XCTAssertEqual(before.libraryIds, ["tv"])
    }

    // MARK: - Persistence

    func testTheOrderSurvivesARelaunchAndHomeRowsKeepTheirShape() throws {
        let first = settings()
        let entries = first.sideMenuEntries(libraryIds: libraryIds)
        let moved = SideMenuOrder.moving(entries, from: [entries.count - 1], to: 3)
        first.applySideMenuOrder(moved)

        let relaunched = HomeScreenSettings(defaults: defaults)
        XCTAssertEqual(relaunched.sideMenuEntries(libraryIds: libraryIds), moved)

        // The Home row key still decodes as plain row configs, list_ rows included.
        let data = try XCTUnwrap(defaults.data(forKey: "homeScreenRowOrder"))
        let saved = try JSONDecoder().decode([HomeRowConfig].self, from: data)
        XCTAssertEqual(saved.map(\.id), homeRows.map(\.id))
        XCTAssertEqual(
            defaults.stringArray(forKey: HomeScreenSettings.sideMenuOrderKey)?.filter { $0.hasPrefix("menu:") },
            ["menu:lists", "menu:library:boxsets", "menu:library:playlists"]
        )
    }

    // MARK: - Rows and libraries changing under a saved order

    /// A saved entry goes back after what it followed; if that has gone (an
    /// unsubscribed list's row here), after the nearest one still there.
    func testASavedEntryOutlivesTheRowItFollowed() {
        let rows = [
            SideMenuOrder.Row(id: "hero", destination: nil),
            SideMenuOrder.Row(id: "library_movies", destination: .library("movies"))
        ]
        let saved = ["hero", "list_gone", "menu:lists", "library_movies"]
        XCTAssertEqual(
            SideMenuOrder.entries(rows: rows, libraryIds: ["movies"], saved: saved),
            [.row("hero"), .menuOnly(.lists), .row("library_movies")]
        )
    }

    /// New rows (a list just subscribed to) land where Home puts them, and the
    /// menu-only entries keep their places around them.
    func testRowsAddedSinceTheSaveDoNotDisplaceMenuOnlyEntries() {
        let rows = ["hero", "continue_watching", "list_new", "channels"].map {
            SideMenuOrder.Row(id: $0, destination: $0 == "channels" ? .finTV : nil)
        }
        let saved = ["menu:library:boxsets", "hero", "continue_watching", "channels", "menu:lists"]
        XCTAssertEqual(
            SideMenuOrder.entries(rows: rows, libraryIds: ["boxsets"], saved: saved),
            [.menuOnly(.library("boxsets")), .row("hero"), .row("continue_watching"), .row("list_new"),
             .row("channels"), .menuOnly(.lists)]
        )
    }

    func testALibraryAddedOnTheServerAfterTheSaveGoesLast() {
        let saved = ["menu:lists", "channels"]
        let rows = [SideMenuOrder.Row(id: "channels", destination: .finTV)]
        XCTAssertEqual(
            SideMenuOrder.entries(rows: rows, libraryIds: ["photos"], saved: saved),
            [.menuOnly(.lists), .row("channels"), .menuOnly(.library("photos"))]
        )
    }

    /// A library that gained a Home row is a row from then on; one the server
    /// dropped is gone.
    func testSavedEntriesThatAreNoLongerMenuOnlyAreIgnored() {
        let rows = [SideMenuOrder.Row(id: "library_music", destination: .library("music"))]
        let saved = ["menu:library:music", "menu:library:gone", "library_music", "menu:lists"]
        XCTAssertEqual(
            SideMenuOrder.entries(rows: rows, libraryIds: ["music"], saved: saved),
            [.row("library_music"), .menuOnly(.lists)]
        )
    }

    // MARK: - Mechanics

    func testMovingMatchesArrayMove() {
        let entries: [SideMenuOrder.Entry] = ["a", "b", "c", "d", "e"].map(SideMenuOrder.Entry.row)
        let cases: [(IndexSet, Int)] = [([0], 3), ([4], 0), ([1, 3], 5), ([2], 2), ([0, 1], 4), ([3], 1)]
        for (source, destination) in cases {
            var expected = entries
            expected.move(fromOffsets: source, toOffset: destination)
            XCTAssertEqual(SideMenuOrder.moving(entries, from: source, to: destination), expected, "\(source) → \(destination)")
        }
    }

    func testStorageKeysRoundTripAndRowIdsStayPlain() {
        let entries: [SideMenuOrder.Entry] = [
            .row("hero"), .row("list_abc"), .row("library_x"), .menuOnly(.lists), .menuOnly(.library("y")), .menuOnly(.finTV)
        ]
        let keys = SideMenuOrder.savedKeys(entries)
        XCTAssertEqual(keys, ["hero", "list_abc", "library_x", "menu:lists", "menu:library:y", "menu:fintv"])
        XCTAssertEqual(keys.map(SideMenuOrder.Entry.init(storageKey:)), entries)
        XCTAssertEqual(SideMenuOrder.Entry(storageKey: "menu:nonsense"), .row("menu:nonsense"))
    }
}
