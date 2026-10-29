import XCTest
@testable import Sashimi

/// Answers from a path → (status, body) table and records each request.
private final class QuickConnectStubServer: URLProtocol {
    struct Recorded {
        let method: String
        let path: String
        let query: [String: String]
        let authorization: String
        let body: Data
    }

    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var recorded: [Recorded] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let record = Recorded(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: query,
            authorization: request.value(forHTTPHeaderField: "Authorization") ?? "",
            body: Self.body(of: request)
        )
        let (status, body) = Self.lock.withLock {
            Self.recorded.append(record)
            return Self.routes[url.path] ?? (404, "")
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The Quick Connect requests, checked against the shapes in Jellyfin 12.4's
/// QuickConnectController and UserController.
final class QuickConnectNetworkTests: XCTestCase {
    private let serverURL = URL(string: "http://stub.local")

    override func setUp() {
        super.setUp()
        QuickConnectStubServer.routes = [:]
        QuickConnectStubServer.recorded = []
        JellyfinClient.testURLProtocolClasses = [QuickConnectStubServer.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func signedOutClient() async throws -> JellyfinClient {
        let client = JellyfinClient()
        await client.configure(serverURL: try XCTUnwrap(serverURL))
        return client
    }

    private static let initiateBody = """
        {"Authenticated":false,"Secret":"abc123","Code":"482917","DeviceId":"d","DeviceName":"Apple TV",\
        "AppName":"Sashimi","AppVersion":"1.0","DateAdded":"2026-10-29T12:00:00Z"}
        """

    func testEnabledReadsTheServersBool() async throws {
        QuickConnectStubServer.routes["/QuickConnect/Enabled"] = (200, "true")
        let enabled = try await signedOutClient().isQuickConnectEnabled()
        XCTAssertTrue(enabled)

        QuickConnectStubServer.routes["/QuickConnect/Enabled"] = (200, "false")
        let disabled = try await signedOutClient().isQuickConnectEnabled()
        XCTAssertFalse(disabled)
    }

    func testAnOlderServerWithoutQuickConnectHidesIt() async throws {
        // No route: 404.
        let enabled = try await signedOutClient().isQuickConnectEnabled()
        XCTAssertFalse(enabled)
    }

    func testInitiatePostsWithoutATokenAndDecodesCodeAndSecret() async throws {
        QuickConnectStubServer.routes["/QuickConnect/Initiate"] = (200, Self.initiateBody)

        let result = try await signedOutClient().initiateQuickConnect()

        XCTAssertEqual(result, QuickConnectResult(secret: "abc123", code: "482917", authenticated: false))
        let request = try XCTUnwrap(QuickConnectStubServer.recorded.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.authorization.hasPrefix("MediaBrowser Client="))
        XCTAssertTrue(request.authorization.contains("DeviceId="))
        XCTAssertFalse(request.authorization.contains("Token="), "a signed-out device has no token to send")
    }

    func testPollingAsksWithTheSecretAndAGoneRequestReadsAsExpired() async throws {
        QuickConnectStubServer.routes["/QuickConnect/Connect"] = (200, Self.initiateBody)
        let service = LiveQuickConnectService()
        let url = try XCTUnwrap(serverURL)

        let pending = try await service.state(serverURL: url, secret: "abc123")
        XCTAssertFalse(pending.authenticated)
        XCTAssertEqual(QuickConnectStubServer.recorded.last?.query["secret"], "abc123")

        QuickConnectStubServer.routes["/QuickConnect/Connect"] = (404, "\"Unknown secret\"")
        do {
            _ = try await service.state(serverURL: url, secret: "abc123")
            XCTFail("a 404 must end the request")
        } catch {
            XCTAssertEqual(error as? QuickConnectError, .expired)
        }
    }

    func testDisabledServerRefusingInitiateIsReportedAsDisabled() async throws {
        QuickConnectStubServer.routes["/QuickConnect/Initiate"] = (401, "\"Quick connect is disabled\"")
        do {
            _ = try await LiveQuickConnectService().initiate(serverURL: try XCTUnwrap(serverURL))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? QuickConnectError, .disabled)
        }
    }

    func testAuthenticateWithQuickConnectSendsTheSecretAndReturnsTheSessionResult() async throws {
        QuickConnectStubServer.routes["/Users/AuthenticateWithQuickConnect"] = (200, """
            {"User":{"Id":"user-a","Name":"sl-test-a"},"AccessToken":"tok","ServerId":"srv"}
            """)
        let client = try await signedOutClient()

        let result = try await client.authenticateWithQuickConnect(secret: "abc123")

        XCTAssertEqual(result.user.id, "user-a")
        XCTAssertEqual(result.accessToken, "tok")
        let request = try XCTUnwrap(QuickConnectStubServer.recorded.last)
        XCTAssertEqual(request.method, "POST")
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: String]
        XCTAssertEqual(body, ["Secret": "abc123"])
        let configured = await client.isConfigured
        XCTAssertTrue(configured, "the client now holds the session, as after a password sign-in")
    }

    // MARK: - Approving from another device (#801)

    private func signedInClient() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(serverURL), accessToken: "phone-token", userId: "user-a")
    }

    func testAuthorizeSendsTheCodeWithThisDevicesToken() async throws {
        QuickConnectStubServer.routes["/QuickConnect/Authorize"] = (200, "true")

        let approved = try await signedInClient().authorizeQuickConnect(code: "482917")

        XCTAssertTrue(approved)
        let request = try XCTUnwrap(QuickConnectStubServer.recorded.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.query["code"], "482917")
        XCTAssertTrue(request.authorization.contains("Token=\"phone-token\""))
    }

    func testAuthorizingAnUnknownCodeIsA404() async throws {
        do {
            _ = try await signedInClient().authorizeQuickConnect(code: "000000")
            XCTFail("expected a 404")
        } catch {
            XCTAssertEqual(QuickConnectApprovalViewModel.message(for: error), "Code not found or expired")
        }
    }

    func testA401FromAuthorizeDoesNotReadAsAnExpiredSession() async throws {
        QuickConnectStubServer.routes["/QuickConnect/Authorize"] = (401, "\"Quick connect is disabled\"")
        do {
            _ = try await signedInClient().authorizeQuickConnect(code: "482917")
            XCTFail("expected an error")
        } catch JellyfinError.invalidCredentials {
            // Quick Connect off: reported, and the phone's session survives.
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
