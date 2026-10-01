import XCTest
@testable import SashimiMobile

/// The iPad rail lists destinations in Home's row order, as the tvOS rail does.
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
            [.library("movies"), .finTV, .library("tv")]
        )
    }

    func testUnlistedLibrariesAndChannelsFollowInServerOrder() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [library("tv")], libraryIds: ["movies", "tv", "music"]),
            [.library("tv"), .library("movies"), .library("music"), .finTV]
        )
    }

    func testRowsForRemovedLibrariesAreDropped() {
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [library("gone"), channels], libraryIds: ["movies"]),
            [.finTV, .library("movies")]
        )
    }

    /// Hidden on Home is not hidden from the rail: it is the only way in.
    func testDisabledRowsKeepTheirPlace() {
        let hiddenMovies = HomeRowConfig(type: .library(id: "movies", name: "Movies"), isEnabled: false)
        XCTAssertEqual(
            RailOrder.destinations(rowConfigs: [channels, hiddenMovies], libraryIds: ["tv", "movies"]),
            [.finTV, .library("movies"), .library("tv")]
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
