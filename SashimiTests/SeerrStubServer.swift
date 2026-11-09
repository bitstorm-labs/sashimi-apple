import Foundation
@testable import Sashimi

/// Answers Seerr (and plex.tv) requests from a table of "METHOD /path" →
/// (status, headers, body) and records every request with its body, so tests
/// can assert what would have been sent without any server. Nothing here
/// ever reaches the network.
final class SeerrStubServer: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var path: String { url.path }
        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    nonisolated(unsafe) private static var routes: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    private static let lock = NSLock()
    /// Seconds to hold every title-details answer (GET /api/v1/movie|tv/{id}), so a
    /// test can watch how many are in flight at once. Zero answers at once.
    nonisolated(unsafe) static var detailsDelay: TimeInterval = 0
    nonisolated(unsafe) private static var detailsInFlight = 0
    nonisolated(unsafe) private static var detailsPeak = 0

    /// The most title-details requests that were open at the same time since `reset()`.
    static var peakDetailsInFlight: Int { lock.withLock { detailsPeak } }

    static func reset() {
        lock.withLock {
            routes = [:]
            recorded = []
            detailsDelay = 0
            detailsInFlight = 0
            detailsPeak = 0
        }
    }

    private static func isDetails(_ method: String, _ path: String) -> Bool {
        method == "GET" && (path.hasPrefix("/api/v1/movie/") || path.hasPrefix("/api/v1/tv/"))
    }

    /// Queue a reply. Several replies for one route are answered in order and
    /// the last one repeats.
    static func on(_ method: String, _ path: String, status: Int = 200, body: String = "{}", headers: [String: String] = [:]) {
        lock.withLock {
            routes["\(method) \(path)", default: []].append(Reply(status: status, body: body, headers: headers))
        }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    static func requests(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// The held-back reply of a delayed details request; cancelled if the request is.
    private var delayedReply: DispatchWorkItem?

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(Recorded(
                method: method,
                url: url,
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            ))
            let key = "\(method) \(url.path)"
            guard var queue = Self.routes[key], let first = queue.first else {
                return Reply(status: 404, body: "{\"message\":\"Not found\"}")
            }
            if queue.count > 1 {
                queue.removeFirst()
                Self.routes[key] = queue
            }
            return first
        }
        var headers = reply.headers
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        let answer = { [self] in
            if let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let delay = Self.lock.withLock { Self.isDetails(method, url.path) ? Self.detailsDelay : 0 }
        guard delay > 0 else { return answer() }
        Self.lock.withLock {
            Self.detailsInFlight += 1
            Self.detailsPeak = max(Self.detailsPeak, Self.detailsInFlight)
        }
        let work = DispatchWorkItem { [self] in
            leaveDetails()
            answer()
        }
        Self.lock.withLock { delayedReply = work }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Leaves the in-flight count once, whether the reply was sent or cancelled.
    private func leaveDetails() {
        let counted = Self.lock.withLock { () -> Bool in
            defer { delayedReply = nil }
            return delayedReply != nil
        }
        if counted { Self.lock.withLock { Self.detailsInFlight -= 1 } }
    }

    override func stopLoading() {
        Self.lock.withLock { delayedReply }?.cancel()
        leaveDetails()
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Keeps cookies in memory so tests never touch the Keychain.
final class InMemorySeerrCredentials: SeerrCredentialStore, @unchecked Sendable {
    private(set) var values: [String: String] = [:]

    func cookie(forKey key: String) -> String? { values[key] }

    func setCookie(_ cookie: String?, forKey key: String) {
        values[key] = cookie
    }
}

enum SeerrFixtures {
    static let server = URL(string: "https://seerr.test")!  // swiftlint:disable:this force_unwrapping
    static let sessionCookie = "connect.sid=s%3Atest-session.sig"
    static let setCookie = "connect.sid=s%3Atest-session.sig; Path=/; Expires=Wed, 01 Dec 2027 00:00:00 GMT; HttpOnly"

    static func user(id: Int = 7, name: String = "mom") -> String {
        "{\"id\":\(id),\"email\":\"mom@example.com\",\"displayName\":\"\(name)\",\"plexToken\":\"must-not-be-kept\",\"createdAt\":\"2026-01-01T00:00:00.000Z\",\"updatedAt\":\"2026-01-01T00:00:00.000Z\"}"
    }

    static func defaults() -> UserDefaults {
        let name = "seerr-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
