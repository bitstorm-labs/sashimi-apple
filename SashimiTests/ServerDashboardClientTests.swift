import XCTest
@testable import Sashimi

/// Records every request the client sends and answers from a path table.
private final class DashboardStub: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
    }

    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, payload) = Self.lock.withLock {
            Self.seen.append(Seen(method: request.httpMethod ?? "GET", path: url.path, query: query, body: body))
            return Self.routes[url.path] ?? (204, "")
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class ServerDashboardClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DashboardStub.routes = [:]
        DashboardStub.seen = []
        JellyfinClient.testURLProtocolClasses = [DashboardStub.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "u1")
    }

    func testStopPostsToThatSessionsStopCommand() async throws {
        try await client().stopPlayback(sessionId: "s1")
        let request = try XCTUnwrap(DashboardStub.seen.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/Sessions/s1/Playing/Stop")
    }

    func testMessagePostsTheTextWithAHeaderAndTimeout() async throws {
        try await client().sendMessage(sessionId: "s1", text: "Restarting in 5")
        let request = try XCTUnwrap(DashboardStub.seen.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/Sessions/s1/Message")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["Text"] as? String, "Restarting in 5")
        XCTAssertEqual(json["Header"] as? String, "Sashimi")
        XCTAssertEqual(json["TimeoutMs"] as? Int, 10_000)
    }

    func testSessionsAskForRecentlyActiveOnes() async throws {
        DashboardStub.routes["/Sessions"] = (200, #"[{"Id":"a","SupportsRemoteControl":true}]"#)
        let sessions = try await client().getActiveSessions()
        XCTAssertEqual(sessions.map(\.id), ["a"])
        XCTAssertEqual(DashboardStub.seen.last?.query["activeWithinSeconds"], "960")
    }

    func testActivityAsksForTheLimit() async throws {
        DashboardStub.routes["/System/ActivityLog/Entries"] = (200, #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await client().getActivityLog(limit: 15)
        XCTAssertEqual(DashboardStub.seen.last?.query["limit"], "15")
    }

    func testAServerWithoutTheStorageEndpointReturnsNil() async throws {
        DashboardStub.routes["/System/Info/Storage"] = (404, "")
        let storage = try await client().getStorageInfo()
        XCTAssertNil(storage)
    }

    func testAForbiddenStorageAnswerIsStillAnError() async throws {
        DashboardStub.routes["/System/Info/Storage"] = (403, "")
        do {
            _ = try await client().getStorageInfo()
            XCTFail("a refusal must not read as 'no storage endpoint'")
        } catch {
            XCTAssertTrue(ServerDashboardLogic.isAccessDenied(error))
        }
    }
}
