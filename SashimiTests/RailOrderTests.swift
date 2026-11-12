import XCTest
@testable import Sashimi

/// The rail lists what Home lists, in the order Home lists it, with Search
/// first until it is moved (A1 parity).
final class RailOrderTests: XCTestCase {
    private func library(_ id: String) -> HomeRowConfig {
        .library(id: id, name: "Library \(id)")
    }

    // MARK: - Order

    func testFollowsConfiguredRowOrder() {
        let configs: [HomeRowConfig] = [
            .builtIn(.hero),
            .builtIn(.channels),
            library("movies"),
            .builtIn(.continueWatching),
            library("tv")
        ]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["tv", "movies"]),
            [.search, .finTV, .library("movies"), .library("tv"), .lists],
            "Row order decides the rail, not the order the server returned libraries in"
        )
    }

    func testMovingChannelsBelowLibrariesMovesItInTheRail() {
        let configs: [HomeRowConfig] = [library("movies"), library("tv"), .builtIn(.channels)]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies", "tv"]),
            [.search, .library("movies"), .library("tv"), .finTV, .lists]
        )
    }

    /// Rows that are not destinations contribute nothing.
    func testHeroAndContinueWatchingAreNotRailEntries() {
        let configs: [HomeRowConfig] = [.builtIn(.hero), .builtIn(.continueWatching)]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: []),
            [.search, .finTV, .lists],
            "FinTV is still reachable even when no config placed it"
        )
    }

    // MARK: - Config and server disagreeing

    func testLibraryTheConfigHasNotSeenYetIsAppended() {
        let configs: [HomeRowConfig] = [.builtIn(.channels), library("movies")]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies", "new"]),
            [.search, .finTV, .library("movies"), .library("new"), .lists],
            "A library added since the order was saved goes behind what the config placed"
        )
    }

    func testLibraryTheServerNoLongerHasIsDropped() {
        let configs: [HomeRowConfig] = [library("gone"), library("movies")]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies"]),
            [.search, .library("movies"), .finTV, .lists]
        )
    }

    func testEmptyConfigFallsBackToServerOrder() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [], libraryIds: ["a", "b"]),
            [.search, .library("a"), .library("b"), .finTV, .lists],
            "A first run with nothing saved still lists everything"
        )
    }

    // MARK: - Visibility

    func testHiddenRowsStillAppear() {
        let configs: [HomeRowConfig] = [
            .builtIn(.channels, visible: false),
            .library(id: "movies", name: "Movies", visible: false)
        ]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies"]),
            [.search, .finTV, .library("movies"), .lists],
            "Hiding a Home row hides it from Home, not from the only way to reach it"
        )
    }

    // MARK: - Duplicates

    func testNoDestinationIsListedTwice() {
        let configs: [HomeRowConfig] = [
            .builtIn(.channels),
            library("movies"),
            .builtIn(.channels),
            library("movies")
        ]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies"]),
            [.search, .finTV, .library("movies"), .lists]
        )
    }
}

/// Lists (shared lists) has its own rail entry after the libraries.
final class TVRailListsTests: XCTestCase {
    private let libraries = [JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil)]

    func testListsComesAfterTheLibrariesAndBeforeSettings() {
        let rows = MainTabView.navRows(rowConfigs: [.library(id: "movies", name: "Movies")], libraries: libraries, hidden: [])
        XCTAssertEqual(rows.map(\.title), ["Home", "Search", "Movies", "SashimiTV", "Lists", "Settings"])
    }

    func testHidingListsTakesItOutOfTheRail() {
        let rows = MainTabView.navRows(rowConfigs: [], libraries: libraries, hidden: [.lists])
        XCTAssertFalse(rows.contains { $0.id == .lists })
    }
}
