import XCTest
@testable import SashimiMobile

/// apple#422: library rows belong to one server. A single shared list let a
/// switch to another server prune the first server's rows and preferences.
@MainActor
final class HomeRowSettingsTests: XCTestCase {
    private let keys = ["homeRowOrder.server-a", "homeRowOrder.server-b"]

    override func tearDown() async throws {
        await MainActor.run {
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
    }

    private func library(_ id: String) -> JellyfinLibrary {
        JellyfinLibrary(id: id, name: id, collectionType: nil, imageTags: nil)
    }

    private func libraryIDs(_ settings: HomeRowSettings) -> [String] {
        settings.rows.compactMap { if case .library(let id, _) = $0.type { return id }; return nil }
    }

    func testEachServerKeepsItsOwnLibraryRows() {
        let settings = HomeRowSettings.shared
        let original = settings.serverID
        defer { settings.use(serverID: original) }

        settings.use(serverID: "server-a")
        settings.updateLibraries([library("lib-a")])
        if let index = settings.rows.firstIndex(where: { $0.id == "lib-a" }) {
            settings.toggleRow(at: index)
        }

        settings.use(serverID: "server-b")
        settings.updateLibraries([library("lib-b")])
        XCTAssertEqual(libraryIDs(settings), ["lib-b"], "The other server's rows must not show here")

        settings.use(serverID: "server-a")
        XCTAssertEqual(libraryIDs(settings), ["lib-a"], "Switching away must not prune this server's rows")
        XCTAssertEqual(settings.rows.first { $0.id == "lib-a" }?.isEnabled, false,
                       "The server's own preferences survive a round trip")
    }
}
