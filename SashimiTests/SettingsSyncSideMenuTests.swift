import XCTest
@testable import Sashimi

/// The `sideMenu` sync value (WORK-106 phase 2, spec vectors S1–S6) through
/// the production service and tvOS adapters, with only the network, the
/// clock and the UserDefaults suite replaced.
@MainActor
final class SettingsSyncSideMenuTests: XCTestCase {
    private typealias Menu = SettingsSync.MenuEntry
    private let getRoute = "GET /DisplayPreferences/sashimi-settings"
    private let path = "/DisplayPreferences/sashimi-settings"
    private let available: [RailOrder.Destination] = [.watchlist, .requests, .dashboard]
    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private var clock: Int64 = 5_000
    private var home = HomeScreenSettings(defaults: UserDefaults())
    private var menu = SideMenuSettings(defaults: UserDefaults())

    /// Featured, Continue Watching, SashimiTV, libraries a and b, Requests:
    /// tvOS's default rows.
    private let defaultRows: [HomeRowConfig] = [
        .builtIn(.hero), .builtIn(.continueWatching), .builtIn(.channels),
        .library(id: "a", name: "A"), .library(id: "b", name: "B"), .builtIn(.requests),
    ]

    /// The side menu those rows give with nothing saved.
    private let defaultLayout = [
        Menu(id: "search", menu: true), Menu(id: "watchlist", menu: true), Menu(id: "hero"), Menu(id: "continueWatching"),
        Menu(id: "fintv", menu: true), Menu(id: "library:a", menu: true), Menu(id: "library:b", menu: true),
        Menu(id: "lists", menu: true), Menu(id: "requests", menu: true), Menu(id: "dashboard", menu: true),
    ]

    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        suiteName = "SettingsSyncSideMenuTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        clock = 5_000
        home = HomeScreenSettings(defaults: defaults)
        home.rowConfigs = defaultRows
        menu = SideMenuSettings(defaults: defaults)
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func service() throws -> SettingsSyncService {
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        let sync = SettingsSyncService(defaults: defaults, client: { client }, now: { [unowned self] in clock },
                                       bindings: [], pushDelay: .zero)
        sync.layoutSource = HomeRowsSettingsSync(settings: home, defaults: defaults)
        sync.sideMenuSource = SideMenuSettingsSync(settings: home, menu: menu)
        return sync
    }

    private func stored(_ prefs: [String: String]) throws -> String {
        let object: [String: Any] = ["Id": "sashimi-settings", "Client": "sashimi", "CustomPrefs": prefs]
        return try XCTUnwrap(String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private func sideMenu(_ entries: [Menu], t: Int64) -> String {
        SettingsSync.encode(.init(value: .menuLayout(entries), t: t))
    }

    private func posted() throws -> [String: String] {
        SettingsSync.customPrefs(in: try XCTUnwrap(JellyfinRouteStub.requests("POST", path).last?.body))
    }

    private func writtenSideMenu() throws -> SettingsSync.Stamped? {
        guard case .valid(let stamped) = SettingsSync.decode(try posted()["sideMenu"], kind: .menuLayout) else { return nil }
        return stamped
    }

    /// What the rail lists between Home and Settings.
    private var railOrder: [RailOrder.Destination] {
        RailOrder.destinations(rowConfigs: home.rowConfigs, libraryIds: ["a", "b"], hidden: menu.hidden,
                               savedOrder: home.sideMenuOrder, available: available)
    }

    // MARK: Codec

    func testMenuIsWrittenOnlyForDestinationsAndMustBeABool() {
        let encoded = SettingsSync.encode(.init(value: .menuLayout([Menu(id: "hero"), Menu(id: "lists", menu: false)]), t: 7))
        XCTAssertEqual(encoded, #"{"t":7,"v":[{"id":"hero"},{"id":"lists","menu":false}]}"#)
        XCTAssertEqual(SettingsSync.decode(encoded, kind: .menuLayout),
                       .valid(.init(value: .menuLayout([Menu(id: "hero"), Menu(id: "lists", menu: false)]), t: 7)))
        XCTAssertEqual(SettingsSync.decode(#"{"t":7,"v":[{"id":"lists","menu":1}]}"#, kind: .menuLayout), .invalid(t: 7))
        XCTAssertEqual(SettingsSync.key("sideMenu")?.kind, .menuLayout)
    }

    func testTheDefaultMenuInSharedIds() {
        XCTAssertEqual(SideMenuSettingsSync(settings: home, menu: menu).currentLayout(), defaultLayout)
    }

    // MARK: Vectors

    /// S1: Lists moved above Search on another device.
    func testS1RemoteOrderIsFollowed() async throws {
        var remote = defaultLayout
        remote.insert(remote.remove(at: 7), at: 0)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 200)]))
        let sync = try service()
        sync.start()
        await sync.reconcile()

        XCTAssertEqual(railOrder, [.lists, .search, .watchlist, .finTV, .library("a"), .library("b"), .requests, .dashboard])
        XCTAssertEqual(sync.stamps["sideMenu"], 200)
        XCTAssertTrue(JellyfinRouteStub.requests("POST", path).isEmpty, "nothing written back")

        // The change notifications the apply posted are not local edits.
        sync.sideMenuChanged()
        sync.layoutChanged()
        XCTAssertEqual(sync.stamps["sideMenu"], 200)
        XCTAssertNil(sync.stamps["homeRows"])
    }

    /// S2: Watchlist switched off elsewhere.
    func testS2RemoteMenuSwitchHidesOnlyThat() async throws {
        var remote = defaultLayout
        remote[1] = Menu(id: "watchlist", menu: false)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 200)]))
        let sync = try service()
        sync.start()
        await sync.reconcile()

        XCTAssertEqual(menu.hidden, [.watchlist])
        XCTAssertNil(home.sideMenuOrder, "the order did not change, so nothing is saved for it")
        XCTAssertEqual(home.rowConfigs, defaultRows)
        XCTAssertEqual(railOrder, [.search, .finTV, .library("a"), .library("b"), .lists, .requests, .dashboard])
    }

    /// S3, and a menu switch stamps `sideMenu` only.
    func testS3TVOSWriteKeepsDownloadsWhereItWas() async throws {
        var remote = defaultLayout
        remote.insert(Menu(id: "downloads", menu: true), at: 2)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 100)]))
        JellyfinRouteStub.routes["POST \(path)"] = (204, "")
        let sync = try service()
        sync.start()
        await sync.reconcile()
        XCTAssertEqual(sync.stamps["sideMenu"], 100)

        clock = 900
        menu.setShown(false, for: .library("b"))
        sync.sideMenuChanged()
        sync.layoutChanged()
        await sync.waitForPendingWork()

        XCTAssertEqual(sync.stamps["sideMenu"], 900)
        XCTAssertNil(sync.stamps["homeRows"], "a menu switch is not a Home edit")
        let written = try XCTUnwrap(try writtenSideMenu())
        XCTAssertEqual(written.t, 900)
        guard case .menuLayout(let entries) = written.value else { return XCTFail("not a menu layout") }
        XCTAssertEqual(entries.map(\.id).prefix(3), ["search", "watchlist", "downloads"])
        XCTAssertEqual(entries.first { $0.id == "library:b" }?.menu, false)
        XCTAssertNil(try posted()["homeRows"])
    }

    /// S4: the newer `homeRows` decides the rows' order; the menu-only
    /// entries keep `sideMenu`'s positions.
    func testS4NewerHomeRowsDecidesTheRowOrder() async throws {
        let homeRows = SettingsSync.encode(.init(value: .layout(HomeRowsSettingsSync.layout(defaultRows)), t: 500))
        let remote = [
            Menu(id: "search", menu: true), Menu(id: "library:b", menu: true), Menu(id: "lists", menu: true),
            Menu(id: "library:a", menu: true), Menu(id: "watchlist", menu: true), Menu(id: "hero"),
            Menu(id: "continueWatching"), Menu(id: "fintv", menu: true), Menu(id: "requests", menu: true),
            Menu(id: "dashboard", menu: true),
        ]
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["homeRows": homeRows, "sideMenu": sideMenu(remote, t: 400)]))
        let sync = try service()
        sync.start()
        await sync.reconcile()

        XCTAssertEqual(home.rowConfigs.map(\.id), defaultRows.map(\.id), "rows A,B as homeRows says")
        XCTAssertEqual(home.sideMenuOrder, ["menu:search", "hero", "menu:lists", "continueWatching", "menu:watchlist",
                                            "channels", "library_a", "library_b", "requests", "menu:dashboard"])
        XCTAssertEqual(sync.stamps["homeRows"], 500)
        XCTAssertEqual(sync.stamps["sideMenu"], 400)
    }

    /// S4 clarified: the same result when `sideMenu` arrives first and the
    /// newer `homeRows` only in a later reconcile.
    func testS4SameResultWhicheverKeyArrivesFirst() async throws {
        let remote = [
            Menu(id: "search", menu: true), Menu(id: "library:b", menu: true), Menu(id: "lists", menu: true),
            Menu(id: "library:a", menu: true), Menu(id: "watchlist", menu: true), Menu(id: "hero"),
            Menu(id: "continueWatching"), Menu(id: "fintv", menu: true), Menu(id: "requests", menu: true),
            Menu(id: "dashboard", menu: true),
        ]
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 400)]))
        let sync = try service()
        sync.start()
        await sync.reconcile()
        XCTAssertEqual(home.rowConfigs.map(\.id), ["library_b", "library_a", "hero", "continueWatching", "channels", "requests"])

        let homeRows = SettingsSync.encode(.init(value: .layout(HomeRowsSettingsSync.layout(defaultRows)), t: 500))
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["homeRows": homeRows, "sideMenu": sideMenu(remote, t: 400)]))
        await sync.reconcile()

        XCTAssertEqual(home.rowConfigs.map(\.id), defaultRows.map(\.id))
        XCTAssertEqual(home.sideMenuOrder, ["menu:search", "hero", "menu:lists", "continueWatching", "menu:watchlist",
                                            "channels", "library_a", "library_b", "requests", "menu:dashboard"])
        XCTAssertEqual(sync.stamps["sideMenu"], 400)
    }

    /// Applying `homeRows` moves rows among their own slots only.
    func testApplyingHomeRowsNeverMovesAMenuOnlyEntry() async throws {
        let saved = ["menu:search", "hero", "menu:lists", "continueWatching", "menu:watchlist",
                     "channels", "library_a", "library_b", "requests", "menu:dashboard"]
        home.applySideMenuOrder(saved.map(SideMenuOrder.Entry.init(storageKey:)))
        let order = ["continueWatching", "hero", "fintv", "library:b", "library:a", "requests"]
        let homeRows = SettingsSync.encode(.init(value: .layout(order.map { .init(id: $0, on: true) }), t: 500))
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["homeRows": homeRows]))
        JellyfinRouteStub.routes["POST \(path)"] = (204, "")
        let sync = try service()
        sync.start()
        XCTAssertEqual(sync.stamps["sideMenu"], 1, "seeded: Lists sits above Continue Watching")
        await sync.reconcile()
        sync.sideMenuChanged()

        XCTAssertEqual(home.sideMenuEntries(libraryIds: ["a", "b"], available: available).map(\.storageKey),
                       ["menu:search", "continueWatching", "menu:lists", "hero", "menu:watchlist",
                        "channels", "library_b", "library_a", "requests", "menu:dashboard"])
        XCTAssertEqual(sync.stamps["sideMenu"], 1, "not a side-menu edit")
    }

    /// The other way round: a newer `sideMenu` moves the rows too, without
    /// stamping `homeRows` (no echo) or touching Home's on/off.
    func testNewerSideMenuMovesTheRows() async throws {
        var remote = defaultLayout
        remote.swapAt(5, 6)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 400)]))
        home.rowConfigs[3].isVisible = false
        let sync = try service()
        sync.start()
        await sync.reconcile()
        sync.layoutChanged()

        XCTAssertEqual(home.rowConfigs.map(\.id), ["hero", "continueWatching", "channels", "library_b", "library_a", "requests"])
        XCTAssertEqual(home.rowConfigs.first { $0.id == "library_a" }?.isVisible, false)
        XCTAssertNil(sync.stamps["homeRows"])
        XCTAssertTrue(JellyfinRouteStub.requests("POST", path).isEmpty)
    }

    /// S5: a row-only id carries no `menu`; Home visibility is untouched.
    func testS5RowOnlyEntryLeavesHomeAlone() async throws {
        home.rowConfigs[1].isVisible = false
        var remote = defaultLayout
        remote.swapAt(2, 3)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 200)]))
        let sync = try service()
        sync.start()
        await sync.reconcile()

        XCTAssertEqual(home.rowConfigs.map(\.id).prefix(2), ["continueWatching", "hero"])
        XCTAssertEqual(home.rowConfigs.map(\.isVisible), [false, true, true, true, true, true])
        XCTAssertTrue(menu.hidden.isEmpty)
    }

    /// S6: an unknown id is ignored here and carried through on a write.
    func testS6UnknownIdIsCarriedThrough() async throws {
        var remote = defaultLayout
        remote.insert(Menu(id: "podcasts", menu: true), at: 1)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 200)]))
        JellyfinRouteStub.routes["POST \(path)"] = (204, "")
        let sync = try service()
        sync.start()
        await sync.reconcile()
        XCTAssertEqual(railOrder, [.search, .watchlist, .finTV, .library("a"), .library("b"), .lists, .requests, .dashboard])

        clock = 900
        menu.setShown(false, for: .lists)
        sync.sideMenuChanged()
        await sync.waitForPendingWork()

        let written = try XCTUnwrap(try writtenSideMenu())
        guard case .menuLayout(let entries) = written.value else { return XCTFail("not a menu layout") }
        XCTAssertEqual(entries[1], Menu(id: "podcasts", menu: true))
    }

    // MARK: Change detection and seeding

    func testAMoveInTheEditorStampsBothKeysButNewRowsDoNot() async throws {
        let sync = try service()
        sync.isEnabled = false
        sync.start()
        XCTAssertNil(sync.stamps["sideMenu"], "the default menu is not seeded")

        clock = 600
        home.rowConfigs.append(.library(id: "c", name: "C"))
        sync.sideMenuChanged()
        sync.layoutChanged()
        XCTAssertNil(sync.stamps["sideMenu"], "a new library is not an edit")
        XCTAssertNil(sync.stamps["homeRows"])

        clock = 700
        let entries = home.sideMenuEntries(libraryIds: ["a", "b", "c"], available: available)
        home.applySideMenuOrder(SideMenuOrder.moving(entries, from: [5], to: 7))
        sync.sideMenuChanged()
        sync.layoutChanged()
        XCTAssertEqual(sync.stamps["sideMenu"], 700)
        XCTAssertEqual(sync.stamps["homeRows"], 700, "rows moved relative to each other")
    }

    func testMovingOnlyAMenuEntryStampsOnlySideMenu() throws {
        let sync = try service()
        sync.isEnabled = false
        sync.start()
        clock = 700
        let entries = home.sideMenuEntries(libraryIds: ["a", "b"], available: available)
        home.applySideMenuOrder(SideMenuOrder.moving(entries, from: [7], to: 0))
        sync.sideMenuChanged()
        sync.layoutChanged()
        XCTAssertEqual(sync.stamps["sideMenu"], 700)
        XCTAssertNil(sync.stamps["homeRows"])
    }

    func testSeedingOnlyWhenClearlyCustomised() throws {
        // An order from before Search was an entry, Lists moved up: customised.
        defaults.set(["hero", "menu:lists", "continueWatching", "channels", "library_a", "library_b", "requests"],
                     forKey: HomeScreenSettings.sideMenuOrderKey)
        home.loadSettings()
        let sync = try service()
        sync.isEnabled = false
        sync.start()
        XCTAssertEqual(sync.stamps["sideMenu"], 1)
    }

    func testSeedingAHiddenEntry() throws {
        menu.setShown(false, for: .dashboard)
        let sync = try service()
        sync.isEnabled = false
        sync.start()
        XCTAssertEqual(sync.stamps["sideMenu"], 1)
    }

    func testAnOrderSavedInTheDefaultPlacesIsNotSeeded() throws {
        // Only the libraries differ from the default, or Requests sits where
        // the app put it before #861: neither is the user's customisation.
        home.rowConfigs = [.builtIn(.hero), .builtIn(.continueWatching), .builtIn(.requests), .builtIn(.channels),
                           .library(id: "b", name: "B"), .library(id: "a", name: "A")]
        home.saveSettings()
        let sync = try service()
        sync.isEnabled = false
        sync.start()
        XCTAssertNil(sync.stamps["sideMenu"])
    }

    /// The A1 migration puts Search on top and Watchlist under it once, for
    /// an order saved without `menu:search`. A synced order arriving on such
    /// a device lands as sent, and the migration never runs over it.
    func testAnAppliedOrderIsNeverMigratedAgain() async throws {
        defaults.set(["hero", "continueWatching", "channels", "library_a", "library_b", "menu:watchlist", "menu:lists", "requests"],
                     forKey: HomeScreenSettings.sideMenuOrderKey)
        home.loadSettings()
        var remote = defaultLayout
        remote.append(remote.remove(at: 1))
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 200)]))
        let sync = try service()
        sync.start()
        await sync.reconcile()

        XCTAssertTrue(SideMenuOrder.isMigrated(home.sideMenuOrder))
        XCTAssertEqual(railOrder, [.search, .finTV, .library("a"), .library("b"), .lists, .requests, .dashboard, .watchlist])
    }

    func testARemoteMenuOnlyLibraryKeepsItsPlaceAndSwitch() async throws {
        var remote = defaultLayout
        remote.insert(Menu(id: "library:coll", menu: false), at: 1)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["sideMenu": sideMenu(remote, t: 200)]))
        let sync = try service()
        sync.start()
        await sync.reconcile()

        XCTAssertEqual(menu.hidden, [.library("coll")])
        XCTAssertEqual(home.sideMenuOrder?.prefix(2), ["menu:search", "menu:library:coll"])
    }
}
