import XCTest
@testable import Sashimi

/// Records each request (with its body, which URLProtocol only sees as a
/// stream) and answers 204.
private final class RecordingServer: URLProtocol {
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.withLock { Self.requests.append((request, body)) }
        let url = request.url ?? URL(fileURLWithPath: "/")
        if let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The two server-facing halves of remote control: the capabilities POST and
/// the `/socket` request.
final class RemoteControlClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RecordingServer.requests = []
        JellyfinClient.testURLProtocolClasses = [RecordingServer.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client(_ url: String) throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: url)), accessToken: "secret-token", userId: "u1")
    }

    // MARK: - Capabilities

    func testCapabilitiesAdvertiseMediaControlAndDisplayMessage() async throws {
        try await client("http://stub.local:9096").registerRemoteControlCapabilities()

        let sent = try XCTUnwrap(RecordingServer.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.path, "/Sessions/Capabilities/Full")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["SupportsMediaControl"] as? Bool, true, "without it the server never reports SupportsRemoteControl")
        XCTAssertEqual(body["SupportedCommands"] as? [String], ["DisplayMessage"])
        XCTAssertEqual(body["PlayableMediaTypes"] as? [String], [], "not a cast target")
        XCTAssertTrue(sent.request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"secret-token\"") ?? false)
    }

    // MARK: - Socket request

    func testSocketRequestForAPlainHTTPServer() async throws {
        let client = try client("http://stub.local:9096")
        let built = await client.remoteControlSocketRequest()
        let request = try XCTUnwrap(built)
        XCTAssertEqual(request.url?.absoluteString, "ws://stub.local:9096/socket")
    }

    func testSocketRequestForAnHTTPSServerUnderABasePath() async throws {
        let client = try client("https://media.example.com/jellyfin")
        let built = await client.remoteControlSocketRequest()
        let request = try XCTUnwrap(built)
        XCTAssertEqual(request.url?.absoluteString, "wss://media.example.com/jellyfin/socket")
    }

    func testSocketTokenTravelsInTheHeaderNotTheURL() async throws {
        let client = try client("http://stub.local:9096")
        let built = await client.remoteControlSocketRequest()
        let request = try XCTUnwrap(built)
        let header = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(header.contains("Token=\"secret-token\""), "the server identifies the session by it")
        XCTAssertTrue(header.contains("DeviceId=\""), "and by the device")
        XCTAssertFalse(request.url?.absoluteString.contains("secret-token") ?? true, "12.2 rejects ?api_key=; URLs get logged")
        XCTAssertNil(request.url?.query)
    }

    func testNoSocketWithoutAToken() async throws {
        let client = JellyfinClient()
        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://stub.local:9096")))
        let request = await client.remoteControlSocketRequest()
        XCTAssertNil(request, "a server but no token is a signed-out device")
    }
}
