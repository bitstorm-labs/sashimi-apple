import Combine
import XCTest
@testable import Sashimi

/// Settings sync against a stubbed server: the production service and client
/// with only the network, the clock and the UserDefaults suite replaced.
@MainActor
final class SettingsSyncServiceTests: XCTestCase {
    private typealias Entry = SettingsSync.LayoutEntry
    private let getRoute = "GET /DisplayPreferences/sashimi-settings"
    private let path = "/DisplayPreferences/sashimi-settings"
    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private var clock: Int64 = 5_000

    override func setUp() {
        super.setUp()
        JellyfinRouteStub.reset()
        JellyfinClient.testURLProtocolClasses = [JellyfinRouteStub.self]
        suiteName = "SettingsSyncServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        clock = 5_000
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func service() throws -> SettingsSyncService {
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "me")
        return SettingsSyncService(defaults: defaults, client: { client }, now: { [unowned self] in clock },
                                   pushDelay: .zero)
    }

    /// A stored entry whose CustomPrefs hold `prefs` (values escaped as JSON strings).
    private func stored(_ prefs: [String: String]) throws -> String {
        let object: [String: Any] = ["Id": "sashimi-settings", "Client": "sashimi", "SortBy": "Name", "CustomPrefs": prefs]
        return try XCTUnwrap(String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private func postedPrefs() throws -> [String: String] {
        let body = try XCTUnwrap(JellyfinRouteStub.requests("POST", path).last?.body)
        return SettingsSync.customPrefs(in: body)
    }

    // MARK: Vectors through the service

    func testV7SyncOffMakesNoRequestButStillStamps() async throws {
        let sync = try service()
        sync.start()
        sync.isEnabled = false
        clock = 7_000
        defaults.set(true, forKey: "autoSkipIntro")
        sync.noteLocalChanges()
        await sync.reconcile()
        await sync.waitForPendingWork()

        XCTAssertEqual(sync.stamps["autoSkipIntro"], 7_000)
        XCTAssertTrue(JellyfinRouteStub.recorded.isEmpty, "sync off: no request at all")
    }

    func testV10AndV6FirstRunPublishesExplicitSettingsOnlyAndKeepsEverythingElse() async throws {
        defaults.set(true, forKey: "autoSkipIntro")
        JellyfinRouteStub.routes[getRoute] = (200, try stored([
            "subscriptions": #"[{"id":"L","seen":[]}]"#, "skipBackLength": "10000", "futureKey": #"{"v":1,"t":9}"#,
        ]))
        JellyfinRouteStub.routes["POST \(path)"] = (204, "")
        let sync = try service()
        sync.start()
        await sync.reconcile()

        let prefs = try postedPrefs()
        XCTAssertEqual(prefs["autoSkipIntro"], #"{"t":1,"v":true}"#)
        XCTAssertNil(prefs["showQualityBadges"], "a default is never published")
        XCTAssertEqual(prefs["subscriptions"], #"[{"id":"L","seen":[]}]"#)
        XCTAssertEqual(prefs["skipBackLength"], "10000")
        XCTAssertEqual(prefs["futureKey"], #"{"v":1,"t":9}"#)
        let body = try XCTUnwrap(JellyfinRouteStub.requests("POST", path).last?.body)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["SortBy"] as? String, "Name", "top-level fields survive")
        XCTAssertEqual(JellyfinRouteStub.requests("POST", path).last?.query["client"], "sashimi")
    }

    func testV1AppliedRemoteValueTakesTheRemoteStampAndIsNotEchoed() async throws {
        let sync = try service()
        sync.start()
        defaults.set(true, forKey: "autoSkipIntro")
        sync.noteLocalChanges()
        clock = 100
        defaults.set(false, forKey: "autoSkipIntro")
        sync.noteLocalChanges()
        XCTAssertEqual(sync.stamps["autoSkipIntro"], 100)
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["autoSkipIntro": #"{"v":true,"t":200}"#]))

        clock = 9_999
        await sync.reconcile()
        sync.noteLocalChanges()

        XCTAssertEqual(defaults.object(forKey: "autoSkipIntro") as? Bool, true)
        XCTAssertEqual(sync.stamps["autoSkipIntro"], 200, "the remote t, not now")
        XCTAssertTrue(JellyfinRouteStub.requests("POST", path).isEmpty, "nothing written back")
    }

    func testALocalChangeIsPushedWhenNewer() async throws {
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["resumeThresholdSeconds": #"{"v":60,"t":200}"#]))
        JellyfinRouteStub.routes["POST \(path)"] = (204, "")
        let sync = try service()
        sync.start()
        clock = 300
        defaults.set(10, forKey: "resumeThresholdSeconds")
        sync.noteLocalChanges()
        await sync.waitForPendingWork()

        XCTAssertEqual(try postedPrefs()["resumeThresholdSeconds"], #"{"t":300,"v":10}"#)
    }

    func testTurningSyncOnReconcilesAndPushesChangesMadeWhileOff() async throws {
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["autoSkipCredits": #"{"v":false,"t":200}"#]))
        JellyfinRouteStub.routes["POST \(path)"] = (204, "")
        let sync = try service()
        sync.start()
        sync.isEnabled = false
        sync.noteLocalChanges()
        clock = 400
        defaults.set(true, forKey: "autoSkipCredits")
        sync.noteLocalChanges()
        XCTAssertTrue(JellyfinRouteStub.recorded.isEmpty)

        sync.isEnabled = true
        sync.noteLocalChanges()
        await sync.reconcile()

        XCTAssertEqual(try postedPrefs()["autoSkipCredits"], #"{"t":400,"v":true}"#)
    }

    func testDefaultViewModeUsesItsAppleKey() async throws {
        JellyfinRouteStub.routes[getRoute] = (200, try stored(["defaultViewMode": #"{"v":"zoom","t":200}"#]))
        let sync = try service()
        sync.start()
        await sync.reconcile()
        XCTAssertEqual(defaults.string(forKey: VideoViewModeStore.defaultModeKey), "zoom")
    }

    // MARK: Layout

    func testRemoteLayoutPlacesRowsThatArriveLater() async throws {
        let rows = FakeLayout(stampKey: "homeRows", rows: [Entry(id: "continueWatching", on: true)])
        JellyfinRouteStub.routes[getRoute] = (200, try stored([
            "homeRows": #"{"v":[{"id":"library:b","on":false},{"id":"continueWatching","on":true},{"id":"library:a","on":true}],"t":200}"#,
        ]))
        let sync = try service()
        sync.layoutSource = rows
        sync.start()
        await sync.reconcile()
        XCTAssertEqual(sync.stamps["homeRows"], 200)

        // Home loads the libraries: an addition, not the user's edit.
        clock = 900
        rows.rows += [Entry(id: "library:a", on: true), Entry(id: "library:b", on: true), Entry(id: "library:c", on: true)]
        sync.layoutChanged()

        // library:c is new to the layout, so it stays after the row it follows here.
        XCTAssertEqual(rows.rows.map(\.id), ["library:b", "library:c", "continueWatching", "library:a"])
        XCTAssertEqual(rows.rows.first?.on, false)
        XCTAssertEqual(sync.stamps["homeRows"], 200, "placing new rows is not a local change")
    }

    func testAUserEditOfTheRowsIsPushedKeepingRemoteOnlyRows() async throws {
        let rows = FakeLayout(stampKey: "homeRows.s1", rows: [Entry(id: "continueWatching", on: true), Entry(id: "library:a", on: true)])
        JellyfinRouteStub.routes[getRoute] = (200, try stored([
            "homeRows": #"{"v":[{"id":"continueWatching","on":true},{"id":"hero","on":true},{"id":"library:a","on":true}],"t":200}"#,
        ]))
        JellyfinRouteStub.routes["POST \(path)"] = (204, "")
        let sync = try service()
        sync.layoutSource = rows
        sync.start()
        await sync.reconcile()

        clock = 900
        rows.rows = [Entry(id: "continueWatching", on: true), Entry(id: "library:a", on: false)]
        sync.layoutChanged()
        await sync.waitForPendingWork()

        XCTAssertEqual(sync.stamps["homeRows.s1"], 900)
        let written = SettingsSync.decode(try postedPrefs()["homeRows"], kind: .layout)
        XCTAssertEqual(written, .valid(.init(value: .layout([
            Entry(id: "continueWatching", on: true), Entry(id: "hero", on: true), Entry(id: "library:a", on: false),
        ]), t: 900)))
    }
}

@MainActor
private final class FakeLayout: SettingsSyncLayoutSource {
    let stampKey: String
    var rows: [SettingsSync.LayoutEntry]
    var isExplicit = false
    private let subject = PassthroughSubject<Void, Never>()

    init(stampKey: String, rows: [SettingsSync.LayoutEntry]) {
        self.stampKey = stampKey
        self.rows = rows
    }

    func currentLayout() -> [SettingsSync.LayoutEntry]? { rows.isEmpty ? nil : rows }

    func apply(_ layout: [SettingsSync.LayoutEntry]) {
        rows = SettingsSync.applyLayout(local: rows, remote: layout)
    }

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
}
