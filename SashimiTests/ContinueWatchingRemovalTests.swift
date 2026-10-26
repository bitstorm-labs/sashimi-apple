import XCTest
@testable import Sashimi

/// Records every request as "METHOD path" (with its body) and answers from a
/// route table; anything not in it is a 404, like a server without the plugin.
private final class RemovalStubServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [(route: String, body: String)] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            routes = [:]
            requests = []
        }
    }

    static func set(_ route: String, _ status: Int, _ body: String = "") {
        lock.withLock { routes[route] = (status, body) }
    }

    static func bodies(for route: String) -> [String] {
        lock.withLock { requests.filter { $0.route == route }.map(\.body) }
    }

    static var routesAsked: [String] {
        lock.withLock { requests.map(\.route) }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let body = Self.readBody(request)
        let (status, payload) = Self.lock.withLock {
            Self.requests.append((route, body))
            return Self.routes[route] ?? (404, "")
        }
        let url = request.url ?? URL(fileURLWithPath: "/")
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(bytes: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

private struct Entry {
    var id: String
    var type = "Episode"
    var series: String?
    var ticks: Int64 = 0
    var played: String? = "2026-10-20T20:00:00Z"
}

private func json(_ entry: Entry) -> String {
    let series = entry.series.map { "\"SeriesId\":\"\($0)\"," } ?? ""
    let date = entry.played.map { "\"LastPlayedDate\":\"\($0)\"," } ?? ""
    return "{\"Id\":\"\(entry.id)\",\"Name\":\"\(entry.id)\",\"Type\":\"\(entry.type)\",\(series)"
        + "\"UserData\":{\(date)\"PlaybackPositionTicks\":\(entry.ticks),\"PlayCount\":0,\"IsFavorite\":false,\"Played\":false}}"
}

private func itemsJSON(_ entries: [Entry]) -> String {
    "{\"Items\":[\(entries.map(json).joined(separator: ","))],\"TotalRecordCount\":\(entries.count)}"
}

private func item(_ entry: Entry) throws -> BaseItemDto {
    try JSONDecoder().decode(BaseItemDto.self, from: Data(json(entry).utf8))
}

// MARK: - The rules

final class ContinueWatchingRemovalRuleTests: XCTestCase {
    func testAMovieOnlyHasItsResumePositionCleared() throws {
        let plan = ContinueWatchingRemoval.plan(for: try item(Entry(id: "m", type: "Movie", ticks: 9_000)))
        XCTAssertEqual(plan, .init(resumeTicks: 9_000, hide: nil))
    }

    func testAPartWatchedEpisodeIsClearedAndItsSeriesHidden() throws {
        let plan = ContinueWatchingRemoval.plan(for: try item(Entry(id: "e5", series: "s", ticks: 42)))
        XCTAssertEqual(plan, .init(resumeTicks: 42, hide: .init(seriesId: "s", episodeId: "e5")))
    }

    func testANextUpEpisodeIsOnlyHidden() throws {
        let plan = ContinueWatchingRemoval.plan(for: try item(Entry(id: "e6", series: "s")))
        XCTAssertFalse(plan.clearsResume, "watched state and position are left alone")
        XCTAssertEqual(plan.hide, .init(seriesId: "s", episodeId: "e6"))
    }

    func testAnEpisodeWithoutASeriesHasNothingToHide() throws {
        XCTAssertNil(ContinueWatchingRemoval.plan(for: try item(Entry(id: "e", ticks: 5))).hide)
    }

    private func hidden(_ series: String, _ episode: String) -> HiddenContinueWatchingEntry {
        HiddenContinueWatchingEntry(seriesId: series, episodeId: episode, hiddenAt: Date(), isOnServer: false)
    }

    func testASeriesStaysHiddenWhileItsNextUpIsTheHiddenEpisode() throws {
        let row = [try item(Entry(id: "e5", series: "s")), try item(Entry(id: "x1", series: "other"))]
        let result = ContinueWatchingRemoval.filter(row, hidden: [hidden("s", "e5")])
        XCTAssertEqual(result.row.map(\.id), ["x1"])
        XCTAssertEqual(result.live.map(\.episodeId), ["e5"])
    }

    func testANewNextUpEpisodeBringsTheSeriesBackAndDropsTheEntry() throws {
        let row = [try item(Entry(id: "e6", series: "s"))]
        let result = ContinueWatchingRemoval.filter(row, hidden: [hidden("s", "e5")])
        XCTAssertEqual(result.row.map(\.id), ["e6"])
        XCTAssertTrue(result.live.isEmpty, "stale: the user moved on")
    }

    func testAnEntryWhoseSeriesIsNotInTheRowIsKept() throws {
        let result = ContinueWatchingRemoval.filter([try item(Entry(id: "x1", series: "other"))], hidden: [hidden("s", "e5")])
        XCTAssertEqual(result.row.map(\.id), ["x1"])
        XCTAssertEqual(result.live.map(\.seriesId), ["s"])
    }

    func testFocusMovesToTheNextCardOrThePreviousWhenLast() {
        XCTAssertEqual(ContinueWatchingRemoval.focusAfterRemoving("b", from: ["a", "b", "c"]), "c")
        XCTAssertEqual(ContinueWatchingRemoval.focusAfterRemoving("c", from: ["a", "b", "c"]), "b")
        XCTAssertNil(ContinueWatchingRemoval.focusAfterRemoving("a", from: ["a"]))
    }
}

// MARK: - The store

@MainActor
final class ContinueWatchingHideStoreTests: XCTestCase {
    private var defaults = UserDefaults.standard
    private let suite = "ContinueWatchingHideStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func entry(_ series: String, _ episode: String) -> HiddenContinueWatchingEntry {
        HiddenContinueWatchingEntry(seriesId: series, episodeId: episode, hiddenAt: Date(timeIntervalSince1970: 0), isOnServer: false)
    }

    func testEntriesAreKeptPerServerAndUser() throws {
        let store = ContinueWatchingHideStore(defaults: defaults)
        let alice = try XCTUnwrap(ContinueWatchingHideStore.scope(serverURL: URL(string: "http://a.local/"), userId: "alice"))
        let bob = try XCTUnwrap(ContinueWatchingHideStore.scope(serverURL: URL(string: "http://a.local"), userId: "bob"))
        store.add(entry("s", "e1"), scope: alice)

        XCTAssertEqual(ContinueWatchingHideStore(defaults: defaults).entries(scope: alice).map(\.episodeId), ["e1"], "persisted")
        XCTAssertTrue(store.entries(scope: bob).isEmpty)
        XCTAssertNil(ContinueWatchingHideStore.scope(serverURL: nil, userId: "alice"))
    }

    func testHidingASeriesAgainReplacesTheOldEntry() {
        let store = ContinueWatchingHideStore(defaults: defaults)
        store.add(entry("s", "e1"), scope: "x")
        store.add(entry("s", "e2"), scope: "x")
        XCTAssertEqual(store.entries(scope: "x").map(\.episodeId), ["e2"])
    }

    func testTheOldestEntriesGoPastTheCap() {
        let store = ContinueWatchingHideStore(defaults: defaults)
        let many = (0...ContinueWatchingHideStore.maxEntries).map { entry("s\($0)", "e\($0)") }
        store.replace(many, scope: "x")
        let kept = store.entries(scope: "x")
        XCTAssertEqual(kept.count, ContinueWatchingHideStore.maxEntries)
        XCTAssertEqual(kept.first?.seriesId, "s1")
    }

    func testRemovingASeriesReturnsWhatWasHidden() {
        let store = ContinueWatchingHideStore(defaults: defaults)
        store.add(entry("s", "e1"), scope: "x")
        store.add(entry("t", "e9"), scope: "x")
        XCTAssertEqual(store.removeSeries("s", scope: "x").map(\.episodeId), ["e1"])
        XCTAssertEqual(store.entries(scope: "x").map(\.seriesId), ["t"])
    }
}

// MARK: - Against a server

/// The whole removal against a stubbed server: with and without the plugin's
/// hide endpoint, on new and old Jellyfin.
@MainActor
final class ContinueWatchingRemovalServerTests: XCTestCase {
    private let user = "u1"
    private var defaults = UserDefaults.standard
    private let suite = "ContinueWatchingRemovalServerTests"

    override func setUp() {
        super.setUp()
        RemovalStubServer.reset()
        JellyfinClient.testURLProtocolClasses = [RemovalStubServer.self]
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func viewModel() throws -> HomeViewModel {
        let client = JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://stub.local")),
            accessToken: "token",
            userId: user
        )
        return HomeViewModel(client: client, hideStore: ContinueWatchingHideStore(defaults: defaults))
    }

    /// No plugin at all: the row is built from Resume + Next Up.
    private func serve(resume: [Entry], nextUp: [Entry]) {
        RemovalStubServer.set("GET /Users/\(user)/Items/Resume", 200, itemsJSON(resume))
        RemovalStubServer.set("GET /Shows/NextUp", 200, itemsJSON(nextUp))
        RemovalStubServer.set("GET /Users/\(user)/Items", 200, itemsJSON([]))
    }

    func testWithoutThePluginANextUpSeriesIsHiddenLocallyUntilItsNextUpMovesOn() async throws {
        serve(resume: [], nextUp: [Entry(id: "e5", series: "s"), Entry(id: "x1", series: "other")])
        let model = try viewModel()
        model.continueWatchingItems = try await model.loadContinueWatching()
        XCTAssertEqual(model.continueWatchingItems.map(\.id), ["e5", "x1"])

        let receipt = await model.removeFromContinueWatching(try item(Entry(id: "e5", series: "s")))

        XCTAssertEqual(RemovalStubServer.routesAsked.filter { $0 == "POST /ContinueWatching/Hidden/e5" }.count, 1, "the plugin is asked first")
        XCTAssertEqual(receipt?.hiddenEntry?.isOnServer, false, "404: kept on this device")
        XCTAssertFalse(RemovalStubServer.routesAsked.contains { $0.hasSuffix("/UserData") }, "nothing to clear")
        XCTAssertEqual(model.continueWatchingItems.map(\.id), ["x1"], "still hidden after the reload")
        XCTAssertEqual(model.removalNotice?.receipt, receipt)

        // Watched elsewhere: Next Up for the series is now e6.
        serve(resume: [], nextUp: [Entry(id: "e6", series: "s"), Entry(id: "x1", series: "other")])
        let row = try await model.loadContinueWatching()
        XCTAssertEqual(row.map(\.id), ["e6", "x1"])
        XCTAssertTrue(ContinueWatchingHideStore(defaults: defaults).entries(scope: "http://stub.local|u1").isEmpty, "stale entry dropped")
    }

    func testAPartWatchedEpisodeHasItsPositionClearedOnTheServerAndUndoRestoresIt() async throws {
        serve(resume: [Entry(id: "e5", series: "s", ticks: 1_200)], nextUp: [])
        RemovalStubServer.set("POST /UserItems/e5/UserData", 200)
        RemovalStubServer.set("POST /ContinueWatching/Hidden/e5", 204)
        RemovalStubServer.set("DELETE /ContinueWatching/Hidden/e5", 204)
        let model = try viewModel()

        let removed = await model.removeFromContinueWatching(try item(Entry(id: "e5", series: "s", ticks: 1_200)))
        let receipt = try XCTUnwrap(removed)

        XCTAssertEqual(RemovalStubServer.bodies(for: "POST /UserItems/e5/UserData"), ["{\"PlaybackPositionTicks\":0}"])
        XCTAssertEqual(receipt.hiddenEntry?.isOnServer, true, "the plugin stored it")

        await model.undoRemoval(receipt)

        XCTAssertEqual(RemovalStubServer.routesAsked.filter { $0 == "DELETE /ContinueWatching/Hidden/e5" }.count, 1)
        XCTAssertEqual(RemovalStubServer.bodies(for: "POST /UserItems/e5/UserData").last, "{\"PlaybackPositionTicks\":1200}")
        XCTAssertTrue(ContinueWatchingHideStore(defaults: defaults).entries(scope: "http://stub.local|u1").isEmpty)
    }

    func testOlderJellyfinTakesThePerUserUserDataRoute() async throws {
        serve(resume: [Entry(id: "m", type: "Movie", ticks: 50)], nextUp: [])
        RemovalStubServer.set("POST /Users/\(user)/Items/m/UserData", 200)
        let model = try viewModel()

        let receipt = await model.removeFromContinueWatching(try item(Entry(id: "m", type: "Movie", ticks: 50)))

        XCTAssertNotNil(receipt)
        XCTAssertEqual(RemovalStubServer.bodies(for: "POST /Users/\(user)/Items/m/UserData"), ["{\"PlaybackPositionTicks\":0}"])
        XCTAssertFalse(RemovalStubServer.routesAsked.contains { $0.contains("/ContinueWatching/Hidden") }, "movies are never hidden")
    }

    func testAMovieThatCannotBeClearedIsReportedAndPutBack() async throws {
        serve(resume: [Entry(id: "m", type: "Movie", ticks: 50)], nextUp: [])
        let model = try viewModel()

        let receipt = await model.removeFromContinueWatching(try item(Entry(id: "m", type: "Movie", ticks: 50)))

        XCTAssertNil(receipt)
        XCTAssertEqual(model.removalNotice, .failed(try item(Entry(id: "m", type: "Movie"))))
        XCTAssertEqual(model.continueWatchingItems.map(\.id), ["m"], "the row tells the truth")
    }

    func testPlayingAnEpisodeOfAHiddenSeriesBringsItBack() async throws {
        let store = ContinueWatchingHideStore(defaults: defaults)
        store.add(
            HiddenContinueWatchingEntry(seriesId: "s", episodeId: "e5", hiddenAt: Date(), isOnServer: true),
            scope: "http://stub.local|u1"
        )
        RemovalStubServer.set("DELETE /ContinueWatching/Hidden/e5", 204)
        let client = JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "t", userId: user)

        await store.playbackStarted(of: try item(Entry(id: "e3", series: "s")), client: client)

        XCTAssertTrue(store.entries(scope: "http://stub.local|u1").isEmpty)
        XCTAssertTrue(RemovalStubServer.routesAsked.contains("DELETE /ContinueWatching/Hidden/e5"), "the plugin's hide is lifted too")
    }
}
