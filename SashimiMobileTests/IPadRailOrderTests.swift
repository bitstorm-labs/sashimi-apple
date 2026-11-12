import XCTest
@testable import SashimiMobile

/// The iPad rail lists destinations in Home's row order, as the tvOS rail does,
/// with Search first until it is moved (A1 parity).
final class IPadRailOrderTests: XCTestCase {
    private func library(_ id: String) -> HomeRowConfig {
        HomeRowConfig(type: .library(id: id, name: "Library \(id)"), isEnabled: true)
    }

    private let channels = HomeRowConfig(type: .builtIn(.channels), isEnabled: true)
    private let continueWatching = HomeRowConfig(type: .builtIn(.continueWatching), isEnabled: true)

    func testFollowsHomeRowOrder() {
        XCTAssertEqual(
            RailOrder.destinations(
                rowConfigs: [continueWatching, library("movies"), channels, library("tv")],
                libraryIds: ["tv", "movies"]
            ),
            [.search, .library("movies"), .finTV, .library("tv"), .lists]
        )
    }

    func testUnlistedLibrariesAndChannelsFollowInServerOrder() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [library("tv")], libraryIds: ["movies", "tv", "music"]),
            [.search, .library("tv"), .library("movies"), .library("music"), .finTV, .lists]
        )
    }

    func testRowsForRemovedLibrariesAreDropped() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [library("gone"), channels], libraryIds: ["movies"]),
            [.search, .finTV, .library("movies"), .lists]
        )
    }

    /// Hidden on Home is not hidden from the rail: it is the only way in.
    func testDisabledRowsKeepTheirPlace() {
        let hiddenMovies = HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: false)
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [channels, hiddenMovies], libraryIds: ["tv", "movies"]),
            [.search, .finTV, .library("movies"), .library("tv"), .lists]
        )
    }

    func testLibraryIconsMatchTheTVRail() {
        XCTAssertEqual(
            SidebarSelection.library(id: "1", name: "Movies", collectionType: "movies").icon,
            "film.stack"
        )
        XCTAssertEqual(
            SidebarSelection.library(id: "2", name: "YouTube", collectionType: "tvshows").icon,
            "play.rectangle.fill"
        )
    }
}
