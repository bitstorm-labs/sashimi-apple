import XCTest
@testable import Sashimi

/// The rail lists what Home lists, in the order Home lists it.
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
            [.finTV, .library("movies"), .library("tv")],
            "Row order decides the rail, not the order the server returned libraries in"
        )
    }

    func testMovingChannelsBelowLibrariesMovesItInTheRail() {
        let configs: [HomeRowConfig] = [library("movies"), library("tv"), .builtIn(.channels)]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies", "tv"]),
            [.library("movies"), .library("tv"), .finTV]
        )
    }

    /// Rows that are not destinations contribute nothing.
    func testHeroAndContinueWatchingAreNotRailEntries() {
        let configs: [HomeRowConfig] = [.builtIn(.hero), .builtIn(.continueWatching)]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: []),
            [.finTV],
            "FinTV is still reachable even when no config placed it"
        )
    }

    // MARK: - Config and server disagreeing

    func testLibraryTheConfigHasNotSeenYetIsAppended() {
        let configs: [HomeRowConfig] = [.builtIn(.channels), library("movies")]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies", "new"]),
            [.finTV, .library("movies"), .library("new")],
            "A library added since the order was saved goes behind what the config placed"
        )
    }

    func testLibraryTheServerNoLongerHasIsDropped() {
        let configs: [HomeRowConfig] = [library("gone"), library("movies")]

        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: configs, libraryIds: ["movies"]),
            [.library("movies"), .finTV]
        )
    }

    func testEmptyConfigFallsBackToServerOrder() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [], libraryIds: ["a", "b"]),
            [.library("a"), .library("b"), .finTV],
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
            [.finTV, .library("movies")],
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
            [.finTV, .library("movies")]
        )
    }
}
