import XCTest
@testable import Sashimi

/// Answers "METHOD /path" from a table and records every request with its body.
final class JellyfinRouteStub: URLProtocol {
    struct Recorded {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
    }

    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    /// Answers given in turn, before `routes`; the last one repeats.
    nonisolated(unsafe) static var sequences: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var recorded: [Recorded] = []
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, text) = Self.lock.withLock {
            Self.recorded.append(Recorded(method: method, path: url.path, query: query, body: body))
            let key = "\(method) \(url.path)"
            if var answers = Self.sequences[key], let first = answers.first {
                if answers.count > 1 { answers.removeFirst() }
                Self.sequences[key] = answers
                return first
            }
            return Self.routes[key] ?? (404, "")
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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

    static func requests(_ method: String, _ path: String) -> [Recorded] {
        lock.withLock { recorded.filter { $0.method == method && $0.path == path } }
    }
}
