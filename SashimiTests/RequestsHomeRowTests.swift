import XCTest
@testable import Sashimi

/// Requests is a Home row (#861): Home drew the Seerr requests row pinned
/// after the first row while the side menu listed Requests last, so the two
/// disagreed and Settings could move only the menu entry. Now the row carries
/// the menu entry, the way SashimiTV's and the libraries' rows do. A fresh
/// install has it after the libraries (A1 parity); saved orders without it
/// still get it right after Continue Watching.
@MainActor
final class RequestsHomeRowTests: XCTestCase {
    private let suite = "RequestsHomeRowTests"
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
    private var libraryIds: [String] { libraries.map(\.id) }
    /// Home has rows for Movies and TV Shows; Collections is menu-only.
    private var homeLibraries: [JellyfinLibrary] { Array(libraries.prefix(2)) }
    private let both: [RailOrder.Destination] = [.requests, .dashboard]

    /// A row order saved before Requests was a row, moved about by the user.
    private let savedBeforeRequests: [HomeRowConfig] = [
        .builtIn(.channels),
        .builtIn(.hero),
        .library(id: "tv", name: "TV Shows"),
        .builtIn(.continueWatching),
        .library(id: "movies", name: "Movies"),
        .list(id: "abc", title: "From Chad: Halloween")
    ]

    private func settings(saving rows: [HomeRowConfig]? = nil) -> HomeScreenSettings {
        if let rows {
            let seed = HomeScreenSettings(defaults: defaults)
            seed.rowConfigs = rows
            seed.saveSettings()
        }
        let settings = HomeScreenSettings(defaults: defaults)
        settings.updateWithLibraries(homeLibraries)
        return settings
    }

    private func rail(_ settings: HomeScreenSettings, available: [RailOrder.Destination] = [.requests]) -> [RailOrder.Destination] {
        RailOrder.destinations(
            rowConfigs: settings.rowConfigs,
            libraryIds: libraryIds,
            hidden: [],
            savedOrder: settings.sideMenuOrder,
            available: available
        )
    }

    // MARK: The row

    func testRequestsIsABuiltInRowThatStandsForTheMenuEntry() {
        XCTAssertEqual(HomeRowType.requests.rawValue, "requests", "the raw value is saved and never changes")
        XCTAssertEqual(HomeRowType.requests.displayName, "Requests")
        XCTAssertEqual(HomeRowConfig.builtIn(.requests).railDestination, .requests)
    }

    func testANewInstallHasItAfterTheLibraries() {
        XCTAssertEqual(
            settings().rowConfigs.map(\.id),
            ["hero", "continueWatching", "channels", "library_movies", "library_tv", "requests"]
        )
    }

    func testASavedOrderWithoutItGetsItRightAfterContinueWatchingAndNothingElseMoves() {
        let expected = ["channels", "hero", "library_tv", "continueWatching", "requests", "library_movies", "list_abc"]
        // Before Home has loaded the libraries (the rail reads this too) ...
        let seed = HomeScreenSettings(defaults: defaults)
        seed.rowConfigs = savedBeforeRequests
        seed.saveSettings()
        XCTAssertEqual(HomeScreenSettings(defaults: defaults).rowConfigs.map(\.id), expected)
        // ... and after.
        XCTAssertEqual(settings().rowConfigs.map(\.id), expected)
    }

    func testAHiddenOrMovedRequestsRowStaysAsSaved() {
        let first = settings()
        if let requests = first.rowConfigs.first(where: { $0.type == .requests }) {
            first.toggleVisibility(for: requests)
        }
        let entries = first.sideMenuEntries(libraryIds: libraryIds, available: [.requests])
        let index = entries.firstIndex(of: .row("requests")) ?? 0
        first.applySideMenuOrder(SideMenuOrder.moving(entries, from: [index], to: 0))

        let relaunched = settings()
        XCTAssertEqual(relaunched.rowConfigs.first?.id, "requests")
        XCTAssertEqual(relaunched.isRowVisible(.requests), false)
    }

    // MARK: One entry, one place

    func testTheMenuListsRequestsWhereItsRowIs() {
        let settings = settings()
        XCTAssertEqual(
            rail(settings),
            [.search, .finTV, .library("movies"), .library("tv"), .library("boxsets"), .lists, .requests]
        )
        XCTAssertEqual(
            MainTabView.navRows(rowConfigs: settings.rowConfigs, libraries: libraries, hidden: [], available: [.requests])
                .map(\.title),
            ["Home", "Search", "SashimiTV", "Movies", "TV Shows", "Collections", "Lists", "Requests", "Settings"]
        )
    }

    func testMovingTheRowMovesTheMenuEntry() {
        let settings = settings()
        let entries = settings.sideMenuEntries(libraryIds: libraryIds, available: both)
        XCTAssertEqual(entries.filter { $0 == .row("requests") || $0 == .menuOnly(.requests) }, [.row("requests")],
                       "Settings lists Requests once, as the row")
        let requests = entries.firstIndex(of: .row("requests")) ?? 0
        let movies = entries.firstIndex(of: .row("library_movies")) ?? 0
        settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [requests], to: movies + 1))

        XCTAssertEqual(settings.rowConfigs.map(\.id), ["hero", "continueWatching", "channels", "library_movies", "requests", "library_tv"])
        XCTAssertEqual(
            rail(settings, available: both),
            [.search, .finTV, .library("movies"), .requests, .library("tv"), .library("boxsets"), .lists, .dashboard]
        )
    }

    func testAMenuRequestsKeySavedBeforeTheRowIsIgnored() {
        // #845 let Requests move as a menu-only entry: here, to the top.
        defaults.set(["menu:requests", "hero", "continueWatching", "channels", "library_movies", "library_tv"],
                     forKey: HomeScreenSettings.sideMenuOrderKey)
        let settings = settings()
        XCTAssertEqual(
            rail(settings),
            [.search, .finTV, .library("movies"), .library("tv"), .library("boxsets"), .lists, .requests]
        )
        XCTAssertEqual(
            Array(settings.sideMenuEntries(libraryIds: libraryIds, available: [.requests]).prefix(2)),
            [.menuOnly(.search), .row("hero")]
        )
        if let requests = settings.rowConfigs.firstIndex(where: { $0.type == .requests }),
           let channels = settings.rowConfigs.firstIndex(where: { $0.type == .channels }) {
            settings.rowConfigs.move(fromOffsets: [requests], toOffset: channels + 1)
        }
        XCTAssertEqual(rail(settings).prefix(3), [.search, .finTV, .requests], "the row, not the stale key, decides")
    }

    func testHiddenOnHomeItStaysInTheMenu() {
        let settings = settings()
        if let requests = settings.rowConfigs.first(where: { $0.type == .requests }) {
            settings.toggleVisibility(for: requests)
        }
        XCTAssertTrue(rail(settings).contains(.requests))
        XCTAssertFalse(RailOrder.destinations(
            rowConfigs: settings.rowConfigs, libraryIds: libraryIds, hidden: [.requests], available: [.requests]
        ).contains(.requests), "the side-menu switch is what takes it out (#753)")
    }

    // MARK: Settings lists it only with a Seerr account

    func testSettingsListsTheRowOnlyWhileSeerrIsConnectedOrExpired() {
        let settings = settings()
        let user = SeerrUser(id: 45, displayName: "test")
        for (state, listed) in [(SeerrAuthState.notConfigured, false), (.signedIn(user), true), (.expired, true), (.awaitingPlex(code: "K7QF"), false)] {
            let available = RailOrder.conditionalDestinations(seerr: state, canViewDashboard: false)
            XCTAssertEqual(settings.sideMenuEntries(libraryIds: libraryIds, available: available).contains(.row("requests")), listed, "\(state)")
            XCTAssertEqual(rail(settings, available: available).contains(.requests), listed, "\(state)")
        }
    }

    func testMovingOtherRowsWhileSignedOutLeavesItAfterTheRowItFollowed() {
        let settings = settings()
        let entries = settings.sideMenuEntries(libraryIds: libraryIds)
        let movies = entries.firstIndex(of: .row("library_movies")) ?? 0
        settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [movies], to: 0))

        XCTAssertEqual(settings.rowConfigs.map(\.id), ["library_movies", "hero", "continueWatching", "channels", "library_tv", "requests"])
    }
}
