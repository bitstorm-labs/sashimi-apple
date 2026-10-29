import XCTest
@testable import Sashimi

/// Settings › Server Plugins: Jellyfin status mapping, GUID matching, the
/// skip-segment roll-up and the "5 of 5 found" subtitle.
final class ServerPluginsCatalogTests: XCTestCase {
    private func plugin(_ name: String, _ version: String, _ status: ServerPluginStatus, _ id: String?) -> InstalledPluginInfo {
        InstalledPluginInfo(name: name, version: version, status: status, id: id)
    }

    private func row(_ rows: [ServerPluginRow], _ plugin: SashimiPlugin) throws -> ServerPluginRow {
        try XCTUnwrap(rows.first { $0.plugin == plugin })
    }

    // MARK: Status mapping

    func testPluginsResponseDecodesEveryJellyfinStatus() throws {
        let json = """
        [{"Name":"A","Version":"1.0.0","Status":"Active","Id":"a"},
         {"Name":"B","Version":"1","Status":"Restart","Id":"b"},
         {"Name":"C","Version":"1","Status":"Deleted","Id":"c"},
         {"Name":"D","Version":"1","Status":"Disabled","Id":"d"},
         {"Name":"E","Version":"1","Status":"NotSupported","Id":"e"},
         {"Name":"F","Version":"1","Status":"Malfunctioned","Id":"f"},
         {"Name":"G","Version":"1","Status":"Superceded","Id":"g"},
         {"Name":"H","Version":"1","Status":5,"Id":"h"},
         {"Name":"I","Version":"1","Status":"Sideways","Id":"i"}]
        """
        let decoded = try JSONDecoder().decode([InstalledPluginInfo].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.map(\.status), [
            .active, .restart, .deleted, .disabled, .notSupported, .malfunctioned, .superseded,
            .malfunctioned, .unknown("Sideways")
        ])
        XCTAssertEqual(decoded.first?.version, "1.0.0")
    }

    func testEachStatusHasTheMockupsLabelAndTone() {
        struct Expected {
            let status: ServerPluginStatus
            let label: String
            let tone: DashboardTone
        }
        let expected = [
            Expected(status: .active, label: "Active", tone: .ok),
            Expected(status: .restart, label: "Restart needed", tone: .warning),
            Expected(status: .deleted, label: "Removed on restart", tone: .warning),
            Expected(status: .disabled, label: "Disabled", tone: .warning),
            Expected(status: .notSupported, label: "Not supported", tone: .failure),
            Expected(status: .malfunctioned, label: "Failed to load", tone: .failure),
            Expected(status: .superseded, label: "Superseded", tone: .neutral)
        ]
        for item in expected {
            XCTAssertEqual(PluginRowBadge.status(item.status).label, item.label, "\(item.status)")
            XCTAssertEqual(PluginRowBadge.status(item.status).tone, item.tone, "\(item.status)")
        }
        XCTAssertEqual(PluginRowBadge.notInstalled.label, "Not installed")
        XCTAssertEqual(PluginRowBadge.detected.label, "Detected")
        XCTAssertEqual(PluginRowBadge.notDetected.label, "Not detected")
        XCTAssertEqual(PluginRowBadge.adminOnly.label, "Only an admin can check this")
    }

    func testAProblemStatusSaysWhatBreaks() throws {
        let rows = ServerPluginCatalog.adminRows(installed: [
            plugin("Channels", "0.11.0", .restart, "7a3f1c925d644b089f216c8e5b0a4d73")
        ])
        let channels = try row(rows, .channels)
        XCTAssertEqual(channels.badge, .status(.restart))
        XCTAssertEqual(channels.version, "0.11.0")
        XCTAssertEqual(channels.detail, "SashimiTV channels won't appear until Jellyfin restarts")
        XCTAssertEqual(try row(rows, .lists).badge, .notInstalled)
        XCTAssertEqual(try row(rows, .lists).detail, "Shared lists won't show who owns them until this is installed")
        XCTAssertNil(try row(rows, .lists).version)
    }

    // MARK: GUID matching

    func testDashedUppercaseAndDashlessGUIDsAllMatch() throws {
        let forms = [
            "7a3f1c925d644b089f216c8e5b0a4d73",
            "7a3f1c92-5d64-4b08-9f21-6c8e5b0a4d73",
            "7A3F1C92-5D64-4B08-9F21-6C8E5B0A4D73",
            "{7a3f1c92-5d64-4b08-9f21-6c8e5b0a4d73}"
        ]
        for form in forms {
            let rows = ServerPluginCatalog.adminRows(installed: [plugin("Renamed by someone", "0.11.0", .active, form)])
            XCTAssertEqual(try row(rows, .channels).badge, .status(.active), form)
        }
    }

    func testNameIsOnlyAFallbackWhenNoGUIDMatches() throws {
        let byName = ServerPluginCatalog.adminRows(installed: [plugin("Theme Songs", "1.0.4", .active, "00000000000000000000000000000000")])
        XCTAssertEqual(try row(byName, .themeSongs).version, "1.0.4")

        // A plugin carrying Theme Songs' GUID wins over one merely named so.
        let both = ServerPluginCatalog.adminRows(installed: [
            plugin("Theme Songs", "9.9.9", .active, "ffffffffffffffffffffffffffffffff"),
            plugin("Something", "1.0.4", .restart, "d8d1d1a1-4d9e-4d55-9a2e-0a0a1f5b7c31")
        ])
        XCTAssertEqual(try row(both, .themeSongs).badge, .status(.restart))
        XCTAssertEqual(try row(both, .themeSongs).version, "1.0.4")
    }

    func testAnUpdatedPluginShowsTheActiveCopyNotTheSupersededOne() throws {
        let rows = ServerPluginCatalog.adminRows(installed: [
            plugin("Continue Watching", "0.1.1", .superseded, "a286cbd2ce2246adad0fd49491cce52a"),
            plugin("Continue Watching", "0.2.0", .active, "a286cbd2-ce22-46ad-ad0f-d49491cce52a")
        ])
        XCTAssertEqual(try row(rows, .continueWatching).version, "0.2.0")
        XCTAssertEqual(try row(rows, .continueWatching).badge, .status(.active))
    }

    // MARK: Skip segments roll-up

    func testSkipSegmentsCountsActiveProvidersAndListsThem() {
        let rows = ServerPluginCatalog.skipSegmentsRow(installed: [
            plugin("Intro Skipper", "12.0.6", .active, "c83d86bba1e04c35a113e2101cf4ee6b"),
            plugin("TheIntroDB", "1.3.0", .active, "c9e41b95-63e4-45e2-9db6-b83df21ae5e7"),
            plugin("Segment Editor", "12.0.20", .active, "ace21d44a4e54a85ae75acd2e24a9574")
        ])
        XCTAssertEqual(rows.badge, .providers(3))
        XCTAssertEqual(rows.badge.label, "3 providers")
        XCTAssertEqual(rows.providerLine, "Intro Skipper 12.0.6 · TheIntroDB 1.3.0 · Segment Editor 12.0.20")
        XCTAssertEqual(rows.detail, "Skip Intro / Skip Credits buttons")
    }

    func testOneProviderIsEnoughForSkipSegments() {
        let rows = ServerPluginCatalog.skipSegmentsRow(installed: [
            plugin("Segment Editor", "12.0.20", .active, "ace21d44a4e54a85ae75acd2e24a9574")
        ])
        XCTAssertEqual(rows.badge, .providers(1))
        XCTAssertEqual(rows.badge.label, "1 provider")
        XCTAssertEqual(rows.providerLine, "Segment Editor 12.0.20")
    }

    func testSkipSegmentsWithNoActiveProviderTakesTheBestProviderStatus() {
        let restarting = ServerPluginCatalog.skipSegmentsRow(installed: [
            plugin("Intro Skipper", "12.0.6", .malfunctioned, "c83d86bba1e04c35a113e2101cf4ee6b"),
            plugin("TheIntroDB", "1.3.0", .restart, "c9e41b9563e445e29db6b83df21ae5e7")
        ])
        XCTAssertEqual(restarting.badge, .status(.restart))
        XCTAssertEqual(restarting.detail, "Skip Intro and Skip Credits won't appear until Jellyfin restarts")

        let none = ServerPluginCatalog.skipSegmentsRow(installed: [plugin("Other", "1", .active, "1234")])
        XCTAssertEqual(none.badge, .notInstalled)
        XCTAssertNil(none.providerLine)
    }

    // MARK: Summary

    private func liveServer() -> [InstalledPluginInfo] {
        [
            plugin("Sashimi Lists", "0.1.0", .active, "d95b448462cb487392c566a65b86b420"),
            plugin("Channels", "0.11.0", .active, "7a3f1c925d644b089f216c8e5b0a4d73"),
            plugin("Continue Watching", "0.2.0", .active, "a286cbd2ce2246adad0fd49491cce52a"),
            plugin("Theme Songs", "1.0.4", .active, "d8d1d1a14d9e4d559a2e0a0a1f5b7c31"),
            plugin("Intro Skipper", "12.0.6", .active, "c83d86bba1e04c35a113e2101cf4ee6b")
        ]
    }

    func testSummaryCountsFoundPluginsOnTheServer() {
        let report = ServerPluginsReport(
            isAdministrator: true, serverName: "popcorn", serverVersion: "12.4.0",
            rows: ServerPluginCatalog.adminRows(installed: liveServer())
        )
        XCTAssertEqual(ServerPluginCatalog.summary(for: report), "5 of 5 found on popcorn")
        XCTAssertEqual(report.serverLine, "popcorn · Jellyfin 12.4.0")
    }

    func testSummaryFlagsPluginsThatNeedAttention() {
        var installed = liveServer()
        installed[1] = plugin("Channels", "0.11.0", .malfunctioned, "7a3f1c925d644b089f216c8e5b0a4d73")
        installed.remove(at: 3)
        let report = ServerPluginsReport(
            isAdministrator: true, serverName: "popcorn", serverVersion: nil,
            rows: ServerPluginCatalog.adminRows(installed: installed)
        )
        XCTAssertEqual(ServerPluginCatalog.summary(for: report), "4 of 5 found on popcorn · 1 needs attention")
        XCTAssertEqual(report.serverLine, "popcorn")
    }

    func testNonAdminSummaryCountsOnlyWhatItCouldCheck() {
        let report = ServerPluginsReport(
            isAdministrator: false, serverName: "popcorn", serverVersion: "12.4.0",
            rows: ServerPluginCatalog.probedRows(results: [
                .lists: .detected, .channels: .detected, .continueWatching: .notDetected
            ])
        )
        XCTAssertEqual(ServerPluginCatalog.summary(for: report), "2 of 3 detected on popcorn")
        XCTAssertEqual(report.rows.map(\.badge), [.detected, .detected, .notDetected, .adminOnly, .adminOnly])
        XCTAssertEqual(report.rows[2].detail, "Continue Watching falls back to the app's own order until this is installed")
        XCTAssertEqual(report.rows[3].detail, "Theme music on show and movie pages")
    }
}

// MARK: - Probing routes through JellyfinClient

/// Answers from a path table; a path mapped to `offline` fails like a
/// dropped connection, and an unlisted one is a 404.
private final class PluginRouteStub: URLProtocol {
    static let offline = -1
    nonisolated(unsafe) static var routes: [String: Int] = [:]
    nonisolated(unsafe) static var bodies: [String: String] = [:]
    nonisolated(unsafe) static var requested: [String] = []
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let (status, body) = Self.lock.withLock {
            Self.requested.append(url.path)
            return (Self.routes[url.path] ?? 404, Self.bodies[url.path] ?? "{}")
        }
        guard status != Self.offline else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ServerPluginsProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PluginRouteStub.routes = [:]
        PluginRouteStub.bodies = [:]
        PluginRouteStub.requested = []
        JellyfinClient.testURLProtocolClasses = [PluginRouteStub.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "u1")
    }

    func testProbeReadsTheStatusCode() async throws {
        let client = try client()
        PluginRouteStub.routes = ["/ok": 200, "/forbidden": 403, "/missing": 404, "/broken": 500, "/offline": PluginRouteStub.offline]
        let ok = await client.probePluginRoute(path: "/ok", query: [])
        let forbidden = await client.probePluginRoute(path: "/forbidden", query: [])
        let missing = await client.probePluginRoute(path: "/missing", query: [])
        let broken = await client.probePluginRoute(path: "/broken", query: [])
        let offline = await client.probePluginRoute(path: "/offline", query: [])
        XCTAssertEqual(ok, .detected, "200: the route exists")
        XCTAssertEqual(forbidden, .detected, "403: the route exists, it just refused us")
        XCTAssertEqual(missing, .notDetected, "404: nothing owns the route")
        XCTAssertEqual(broken, .failed, "a 5xx says nothing about the plugin")
        XCTAssertEqual(offline, .failed, "a network error must not read as not installed")
    }

    func testNonAdminProbesEachPluginsOwnRoute() async throws {
        PluginRouteStub.routes = ["/SashimiLists/Owners": 200, "/VirtualChannels": 200, "/ContinueWatching": 404]
        PluginRouteStub.bodies = ["/System/Info/Public": #"{"ServerName":"popcorn","Version":"12.4.0"}"#]
        PluginRouteStub.routes["/System/Info/Public"] = 200
        let model = ServerPluginsViewModel(client: try client())

        await model.refresh(key: "s", isAdministrator: false, fallbackServerName: "Home")

        guard case .loaded(let report) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertFalse(PluginRouteStub.requested.contains("/Plugins"), "a non-admin doesn't ask for /Plugins")
        XCTAssertEqual(report.rows.map(\.badge), [.detected, .detected, .notDetected, .adminOnly, .adminOnly])
        XCTAssertEqual(report.serverLine, "popcorn · Jellyfin 12.4.0")
        XCTAssertEqual(model.subtitle(fallbackServerName: "Home"), "2 of 3 detected on popcorn")
    }

    func testANetworkErrorIsAnErrorNotNotDetected() async throws {
        PluginRouteStub.routes = ["/SashimiLists/Owners": 200, "/VirtualChannels": PluginRouteStub.offline, "/ContinueWatching": 404]
        let model = ServerPluginsViewModel(client: try client())

        await model.refresh(key: "s", isAdministrator: false, fallbackServerName: "Home")

        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.subtitle(fallbackServerName: "Home"), "Couldn't check Home")
    }

    func testAdminReadsPluginsAndMatchesDashedGUIDs() async throws {
        PluginRouteStub.routes = ["/Plugins": 200]
        PluginRouteStub.bodies = ["/Plugins": """
        [{"Name":"Sashimi Lists","Version":"0.1.0","Status":"Active","Id":"d95b4484-62cb-4873-92c5-66a65b86b420"},
         {"Name":"Channels","Version":"0.11.0","Status":"Malfunctioned","Id":"7a3f1c925d644b089f216c8e5b0a4d73"}]
        """]
        let model = ServerPluginsViewModel(client: try client())

        await model.refresh(key: "s", isAdministrator: true, fallbackServerName: "Home")

        guard case .loaded(let report) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertTrue(report.isAdministrator)
        XCTAssertEqual(report.rows.map(\.badge), [.status(.active), .status(.malfunctioned), .notInstalled, .notInstalled, .notInstalled])
        XCTAssertEqual(report.serverName, "Home", "public info failed, so the saved server name is used")
        XCTAssertEqual(model.subtitle(fallbackServerName: "Home"), "2 of 5 found on Home · 1 needs attention")
        XCTAssertFalse(PluginRouteStub.requested.contains("/VirtualChannels"), "an admin doesn't need the probes")
    }

    func testAStaleAdminFlagFallsBackToProbes() async throws {
        PluginRouteStub.routes = ["/Plugins": 403, "/SashimiLists/Owners": 200, "/VirtualChannels": 200, "/ContinueWatching": 200]
        let model = ServerPluginsViewModel(client: try client())

        await model.refresh(key: "s", isAdministrator: true, fallbackServerName: "Home")

        guard case .loaded(let report) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertFalse(report.isAdministrator)
        XCTAssertEqual(model.subtitle(fallbackServerName: "Home"), "3 of 3 detected on Home")
    }

    func testAdminNetworkErrorIsAnError() async throws {
        PluginRouteStub.routes = ["/Plugins": PluginRouteStub.offline]
        let model = ServerPluginsViewModel(client: try client())

        await model.refresh(key: "s", isAdministrator: true, fallbackServerName: "Home")

        XCTAssertEqual(model.state, .failed)
    }

    func testSettingsLoadsOncePerServerAndRefreshAsksAgain() async throws {
        PluginRouteStub.routes = ["/SashimiLists/Owners": 200, "/VirtualChannels": 200, "/ContinueWatching": 200]
        let model = ServerPluginsViewModel(client: try client())
        XCTAssertEqual(model.subtitle(fallbackServerName: "Home"), "Checking Home…")

        await model.loadIfNeeded(key: "a", isAdministrator: false, fallbackServerName: "Home")
        await model.loadIfNeeded(key: "a", isAdministrator: false, fallbackServerName: "Home")
        XCTAssertEqual(PluginRouteStub.requested.filter { $0 == "/VirtualChannels" }.count, 1, "reopening Settings doesn't ask again")

        await model.refresh(key: "a", isAdministrator: false, fallbackServerName: "Home")
        await model.loadIfNeeded(key: "b", isAdministrator: false, fallbackServerName: "Home")
        XCTAssertEqual(PluginRouteStub.requested.filter { $0 == "/VirtualChannels" }.count, 3, "Refresh and a server switch both ask")
    }
}
