import XCTest
@testable import Sashimi

/// Answers the client's requests from a table of path → (status, JSON body) and
/// records which paths were asked for.
private final class StubServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requested: [String] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body) = Self.lock.withLock {
            Self.requested.append(path)
            return Self.routes[path] ?? (404, "")
        }
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Home asks the server's Continue Watching plugin for the row, and only when the
/// server doesn't have it (404) builds the row itself from Resume and Next Up.
@MainActor
final class ServerContinueWatchingTests: XCTestCase {
    private let user = "u1"

    override func setUp() {
        super.setUp()
        StubServer.routes = [:]
        StubServer.requested = []
        JellyfinClient.testURLProtocolClasses = [StubServer.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func items(_ entries: [(id: String, series: String, played: String?)]) -> String {
        let json = entries.map { entry in
            let date = entry.played.map { "\"LastPlayedDate\":\"\($0)\"," } ?? ""
            return "{\"Id\":\"\(entry.id)\",\"Name\":\"\(entry.id)\",\"Type\":\"Episode\",\"SeriesId\":\"\(entry.series)\","
                + "\"UserData\":{\(date)\"PlaybackPositionTicks\":0,\"PlayCount\":0,\"IsFavorite\":false,\"Played\":false}}"
        }
        return "{\"Items\":[\(json.joined(separator: ","))],\"TotalRecordCount\":\(entries.count)}"
    }

    private func viewModel() throws -> HomeViewModel {
        let client = JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://stub.local")),
            accessToken: "token",
            userId: user
        )
        return HomeViewModel(client: client)
    }

    func testThePluginsRowIsUsedAsIsWithoutAskingForResumeOrNextUp() async throws {
        StubServer.routes["/ContinueWatching"] = (200, items([
            (id: "the100-s5e1", series: "the100", played: "2026-09-22T02:11:50Z"),
            (id: "gcn-vo2", series: "gcn", played: "2026-10-12T01:12:39Z")
        ]))

        let row = try await viewModel().loadContinueWatching()

        XCTAssertEqual(row.map(\.id), ["the100-s5e1", "gcn-vo2"], "the server's order, not re-sorted by date")
        XCTAssertFalse(StubServer.requested.contains("/Users/\(user)/Items/Resume"))
        XCTAssertFalse(StubServer.requested.contains("/Shows/NextUp"))
    }

    func testWithoutThePluginTheRowIsMergedFromResumeAndNextUp() async throws {
        StubServer.routes["/Users/\(user)/Items/Resume"] = (200, items([
            (id: "gcn-vo2", series: "gcn", played: "2026-10-12T01:12:39Z")
        ]))
        StubServer.routes["/Shows/NextUp"] = (200, items([
            (id: "older-e2", series: "older", played: "2026-10-01T00:00:00Z")
        ]))
        StubServer.routes["/Users/\(user)/Items"] = (200, items([]))

        let row = try await viewModel().loadContinueWatching()

        XCTAssertTrue(StubServer.requested.contains("/ContinueWatching"), "the plugin is asked first")
        XCTAssertEqual(row.map(\.id), ["gcn-vo2", "older-e2"])
    }
}
