import XCTest
@testable import SashimiMobile

/// The iPhone/iPad/Mac side of the `homeRows` sync value (WORK-106): its
/// rows in shared ids, and a tvOS layout applied to and written from them.
@MainActor
final class HomeRowsSettingsSyncTests: XCTestCase {
    private typealias Entry = SettingsSync.LayoutEntry

    private let rows = [
        HomeRowConfig(type: .builtIn(.continueWatching), isEnabled: true),
        HomeRowConfig(type: .builtIn(.requests), isEnabled: true),
        HomeRowConfig(type: .builtIn(.channels), isEnabled: true),
        HomeRowConfig(type: .library(id: "f137", name: "Movies"), isEnabled: true),
        HomeRowConfig(type: .list(id: "9d1c", title: "From Marge: Picks"), isEnabled: true),
    ]

    func testRowsMapToSharedIds() {
        XCTAssertEqual(HomeRowsSettingsSync.layout(rows).map(\.id),
                       ["continueWatching", "requests", "fintv", "library:f137", "list:9d1c"])
    }

    func testATVOSLayoutAppliesWithoutTheHero() {
        let tvOS = [Entry(id: "hero", on: true), Entry(id: "library:f137", on: false), Entry(id: "continueWatching", on: true),
                    Entry(id: "fintv", on: false), Entry(id: "list:9d1c", on: true), Entry(id: "requests", on: true)]
        let applied = HomeRowsSettingsSync.rows(rows, applying: tvOS)
        XCTAssertEqual(applied.map(\.id), ["f137", "continue_watching", "channels", "list_9d1c", "requests"])
        XCTAssertEqual(applied.map(\.isEnabled), [false, true, false, true, true])
        XCTAssertEqual(applied.first?.displayName, "Recently Added Movies")
    }

    /// V8: writing from here keeps tvOS's hero exactly where it was.
    func testWritingKeepsTheHeroSecond() {
        let remote = [Entry(id: "continueWatching", on: true), Entry(id: "hero", on: true), Entry(id: "requests", on: true)]
        let written = SettingsSync.writeLayout(local: HomeRowsSettingsSync.layout(rows), remote: remote)
        XCTAssertEqual(written.map(\.id), ["continueWatching", "hero", "requests", "fintv", "library:f137", "list:9d1c"])
    }

    func testTheStampAndRowsFollowTheActiveServer() {
        let settings = HomeRowSettings.shared
        let original = settings.serverID
        defer {
            settings.use(serverID: original)
            UserDefaults.standard.removeObject(forKey: "homeRowOrder.sync-test")
        }
        let sync = HomeRowsSettingsSync(settings: settings, activeServerID: { "sync-test" })
        XCTAssertNotNil(sync.currentLayout())
        XCTAssertEqual(settings.serverID, "sync-test", "reading the layout switches to the active server's rows")
        XCTAssertEqual(sync.stampKey, "homeRows.sync-test")
    }

    // MARK: Side menu (phase 2)

    /// iPad/Mac's side menu in shared ids, Downloads included, applied from
    /// another device and kept per server.
    func testSideMenuMapsToSharedIdsAndAppliesPerServer() throws {
        let settings = HomeRowSettings.shared
        let original = settings.serverID
        let suite = "HomeRowsSettingsSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            settings.use(serverID: original)
            UserDefaults.standard.removeObject(forKey: "homeRowOrder.sync-menu")
            UserDefaults.standard.removeObject(forKey: "sideMenuOrder.sync-menu")
            defaults.removePersistentDomain(forName: suite)
        }
        let menu = SideMenuSettings(defaults: defaults)
        let sync = SideMenuSettingsSync(settings: settings, menu: menu, activeServerID: { "sync-menu" })
        _ = sync.currentRows()
        settings.rows = rows
        XCTAssertEqual(sync.stampKey, "sideMenu.sync-menu")

        let layout = try XCTUnwrap(sync.currentLayout())
        XCTAssertEqual(layout.map(\.id), ["search", "watchlist", "continueWatching", "requests", "fintv", "library:f137",
                                          "lists", "list:9d1c", "dashboard", "downloads"])
        XCTAssertEqual(layout.map(\.menu), [true, true, nil, true, true, true, true, nil, true, true])

        var remote = layout
        remote.insert(SettingsSync.MenuEntry(id: "downloads", menu: false), at: 0)
        remote.removeLast()
        sync.apply(remote: remote, rowsFromMenu: true)
        XCTAssertEqual(settings.sideMenuOrder?.first, "menu:downloads")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "sideMenuOrder.sync-menu")?.first, "menu:downloads")
        XCTAssertEqual(menu.hidden, [.downloads])
        XCTAssertEqual(settings.rows.map(\.id), rows.map(\.id), "the rows did not move")
    }

    /// Seeding: Downloads saved before the Dashboard was available sits
    /// above it, the app's doing; Downloads moved above Lists is the user's.
    func testDownloadsAboveTheDashboardIsNotACustomisation() throws {
        let settings = HomeRowSettings.shared
        let original = settings.serverID
        let suite = "HomeRowsSettingsSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            settings.use(serverID: original)
            UserDefaults.standard.removeObject(forKey: "homeRowOrder.sync-seed")
            UserDefaults.standard.removeObject(forKey: "sideMenuOrder.sync-seed")
            defaults.removePersistentDomain(forName: suite)
        }
        let sync = SideMenuSettingsSync(settings: settings, menu: SideMenuSettings(defaults: defaults),
                                        activeServerID: { "sync-seed" })
        _ = sync.currentRows()
        settings.rows = rows
        let rowKeys = rows.map(\.id)
        settings.applySideMenuOrder((["menu:search", "menu:watchlist"] + rowKeys + ["menu:lists", "menu:downloads"])
            .map(SideMenuOrder.Entry.init(storageKey:)))
        XCTAssertFalse(sync.isCustomised)

        settings.applySideMenuOrder((["menu:search", "menu:watchlist", "menu:downloads"] + rowKeys + ["menu:lists"])
            .map(SideMenuOrder.Entry.init(storageKey:)))
        XCTAssertTrue(sync.isCustomised)
    }
}
