import XCTest
@testable import SashimiMobile

/// Requests is a Home row on iPhone, iPad and Mac too (#861): movable and
/// hideable like any row, and on iPad/Mac it carries the side-menu entry, so
/// the menu lists Requests where Home draws it.
@MainActor
final class RequestsHomeRowTests: XCTestCase {
    private let server = "requests-home-row-test"
    private var rowsKey: String { "homeRowOrder.\(server)" }
    private var menuKey: String { "\(HomeRowSettings.sideMenuOrderKey).\(server)" }

    override func tearDown() async throws {
        await MainActor.run {
            [rowsKey, menuKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
    }

    private let libraries = [
        JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
        JellyfinLibrary(id: "tv", name: "TV Shows", collectionType: "tvshows", imageTags: nil)
    ]
    private let movies = SidebarSelection.library(id: "movies", name: "Movies", collectionType: "movies")
    private let tv = SidebarSelection.library(id: "tv", name: "TV Shows", collectionType: "tvshows")

    private func row(_ type: HomeRowConfigType, _ enabled: Bool = true) -> HomeRowConfig {
        HomeRowConfig(type: type, isEnabled: enabled)
    }

    /// Settings for a throwaway server, loaded from `saved` as a relaunch would.
    private func withSettings(saved: [HomeRowConfig]?, _ body: (HomeRowSettings) throws -> Void) rethrows {
        let settings = HomeRowSettings.shared
        let original = settings.serverID
        defer { settings.use(serverID: original) }
        if let saved {
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: rowsKey)
        }
        settings.use(serverID: server)
        try body(settings)
    }

    func testRequestsIsABuiltInRowThatStandsForTheMenuEntry() {
        XCTAssertEqual(HomeRowType.requests.rawValue, "requests", "the raw value is saved and never changes")
        XCTAssertEqual(HomeRowType.requests.displayName, "Requests")
        XCTAssertEqual(row(.builtIn(.requests)).railDestination, .requests)
    }

    func testANewInstallHasItRightAfterContinueWatching() {
        withSettings(saved: nil) { settings in
            XCTAssertEqual(settings.rows.map(\.id), ["continue_watching", "requests", "channels"])
        }
    }

    func testASavedOrderWithoutItGetsItRightAfterContinueWatchingAndNothingElseMoves() {
        let saved = [
            row(.library(id: "tv", name: "TV Shows")),
            row(.builtIn(.channels)),
            row(.builtIn(.continueWatching)),
            row(.library(id: "movies", name: "Movies")),
            row(.list(id: "abc", title: "From Chad: Halloween"))
        ]
        withSettings(saved: saved) { settings in
            XCTAssertEqual(settings.rows.map(\.id), ["tv", "channels", "continue_watching", "requests", "movies", "list_abc"])
        }
    }

    func testTheSideMenuListsRequestsWhereItsRowIs() {
        withSettings(saved: nil) { settings in
            settings.updateLibraries(libraries)
            XCTAssertEqual(
                SidebarSelection.railItems(rowConfigs: settings.rows, libraries: libraries, savedOrder: settings.sideMenuOrder,
                                           available: [.requests, .dashboard]),
                [.home, .requests, .finTV, movies, tv, .lists, .dashboard, .search, .downloads, .settings]
            )
            let entries = settings.sideMenuEntries(libraryIds: libraries.map(\.id), available: [.requests])
            XCTAssertFalse(entries.contains(.menuOnly(.requests)), "one entry: the row")
            let requests = entries.firstIndex(of: .row("requests")) ?? 0
            settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [requests], to: entries.count))
            XCTAssertEqual(
                SidebarSelection.railItems(rowConfigs: settings.rows, libraries: libraries, savedOrder: settings.sideMenuOrder,
                                           available: [.requests]),
                [.home, .finTV, movies, tv, .lists, .requests, .search, .downloads, .settings]
            )
            XCTAssertEqual(settings.rows.last?.id, "requests", "and Home's row moved with it")
        }
    }

    func testTheListOnlyShowsTheRowWithASeerrAccount() {
        withSettings(saved: nil) { settings in
            settings.updateLibraries(libraries)
            XCTAssertFalse(settings.sideMenuEntries(libraryIds: libraries.map(\.id)).contains(.row("requests")))
            XCTAssertFalse(settings.homeRowEntries().contains(.row("requests")), "iPhone's Row Order too")
            XCTAssertTrue(settings.homeRowEntries(available: [.requests]).contains(.row("requests")))
        }
    }

    /// iPhone: no side menu, but the row moves and hides the same way, and
    /// moving others while signed out leaves it where it was.
    func testIPhoneRowOrderMovesItAndLeavesItAloneWhenUnlisted() {
        withSettings(saved: nil) { settings in
            settings.updateLibraries(libraries)
            var entries = settings.homeRowEntries(available: [.requests])
            settings.applyRowOrder(SideMenuOrder.moving(entries, from: [1], to: entries.count))
            XCTAssertEqual(settings.rows.map(\.id), ["continue_watching", "channels", "movies", "tv", "requests"])
            XCTAssertNil(settings.sideMenuOrder, "iPhone has no side menu order to save")

            entries = settings.homeRowEntries(available: [.requests])
            settings.applyRowOrder(SideMenuOrder.moving(entries, from: [4], to: 1))
            entries = settings.homeRowEntries()
            settings.applyRowOrder(SideMenuOrder.moving(entries, from: [entries.count - 1], to: 0))
            XCTAssertEqual(settings.rows.map(\.id), ["tv", "continue_watching", "requests", "channels", "movies"])
        }
    }
    /// Whatever order the rows are in, the iPad/Mac menu lists the
    /// destinations they stand for in that order.
    func testEveryRowOrderGivesTheSameMenuOrder() {
        let rows = [
            row(.builtIn(.continueWatching)), row(.builtIn(.requests)), row(.builtIn(.channels)),
            row(.library(id: "movies", name: "Movies")), row(.library(id: "tv", name: "TV Shows"), false),
            row(.list(id: "abc", title: "From Chad: Halloween"))
        ]
        let selection: [RailOrder.Destination: SidebarSelection] = [.requests: .requests, .finTV: .finTV, .library("movies"): movies, .library("tv"): tv]
        for order in permutations(of: rows) {
            for saved in [nil, ["menu:requests", "menu:lists"], ["menu:dashboard", "movies", "menu:requests"]] as [[String]?] {
                let items = SidebarSelection.railItems(rowConfigs: order, libraries: libraries, savedOrder: saved, available: [.requests, .dashboard])
                let expected = order.compactMap(\.railDestination).compactMap { selection[$0] }
                XCTAssertEqual(items.filter(expected.contains), expected, "\(order.map(\.id)) \(saved ?? [])")
            }
        }
    }

    private func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(of: rest).map { [head] + $0 }
        }
    }
}
