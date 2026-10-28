import XCTest
@testable import SashimiMobile

/// The collapsed iPad/Mac rail is icons only; every icon must carry a hover
/// tooltip naming where it goes (#743).
final class SidebarRailHelpTests: XCTestCase {
    func testEveryRailItemHasANonEmptyTooltip() {
        let libraries = [
            JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
            JellyfinLibrary(id: "tv", name: "TV Shows", collectionType: "tvshows", imageTags: nil),
            JellyfinLibrary(id: "blank", name: "  ", collectionType: nil, imageTags: nil)
        ]
        let rows = [HomeRowConfig(type: .builtIn(.channels), isEnabled: true)]

        let items = SidebarSelection.railItems(rowConfigs: rows, libraries: libraries)

        XCTAssertEqual(items.count, 9, "Home, SashimiTV, three libraries, Lists, Search, Downloads, Settings")
        for item in items {
            XCTAssertFalse(item.helpLabel.trimmingCharacters(in: .whitespaces).isEmpty, "\(item) has no tooltip")
        }
    }

    func testTooltipsNameTheDestination() {
        XCTAssertEqual(SidebarSelection.home.helpLabel, "Home")
        XCTAssertEqual(SidebarSelection.search.helpLabel, "Search")
        XCTAssertEqual(SidebarSelection.downloads.helpLabel, "Downloads")
        XCTAssertEqual(SidebarSelection.settings.helpLabel, "Settings")
        XCTAssertEqual(SidebarSelection.finTV.helpLabel, "SashimiTV")
        XCTAssertEqual(SidebarSelection.library(id: "1", name: "Movies", collectionType: "movies").helpLabel, "Movies")
        XCTAssertEqual(SidebarSelection.library(id: "2", name: "", collectionType: nil).helpLabel, "Library")
    }

    func testAccountButtonTooltip() {
        XCTAssertEqual(SidebarSelection.accountHelpLabel(userName: "mondo"), "mondo — Switch server")
        XCTAssertEqual(SidebarSelection.accountHelpLabel(userName: nil), "Account and servers")
        XCTAssertEqual(SidebarSelection.accountHelpLabel(userName: " "), "Account and servers")
    }
}
