import Foundation
import os

enum SeerrError: LocalizedError, Equatable {
    case invalidServerURL
    /// 401/403 on a signed-in call. Usually an expired session; the session
    /// checks with `/auth/me` before treating it as one.
    case unauthorized
    /// A sign-in the server turned down.
    case invalidCredentials
    /// The server signed us in but sent no session cookie to keep.
    case noSession
    case nothingToRequest
    case server(status: Int, message: String?)
    case decoding
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "That doesn't look like a server address."
        case .unauthorized: return "Seerr didn't allow that."
        case .invalidCredentials: return "That email and password didn't work."
        case .noSession: return "The server signed in but didn't start a session. Check the server address."
        case .nothingToRequest: return "Pick at least one season."
        case .server(_, let message?) where !message.isEmpty: return message
        case .server(let status, _): return "The request server answered with an error (\(status))."
        case .decoding: return "The request server sent something unexpected."
        case .network(let message): return message
        }
    }
}

/// A successful sign-in: who, and the session cookie to send from now on.
struct SeerrSignIn: Sendable {
    let user: SeerrUser
    let cookie: String
}

/// Talks to one Seerr server as one signed-in person, with the `connect.sid`
/// session cookie Seerr hands out on sign-in. The cookie is managed here,
/// not by URLSession's cookie store, so it lives only in the Keychain (see
/// `SeerrSession`) and is never shared with Jellyfin requests. Nothing here
/// logs a cookie, token or password.
actor SeerrClient {
    /// Tests only: URLProtocol classes put in front of every client (and Plex
    /// PIN client) created afterwards.
    nonisolated(unsafe) static var testURLProtocolClasses: [AnyClass] = []

    static let sessionCookieName = "connect.sid"

    let baseURL: URL
    private var cookie: String?
    private let session: URLSession
    private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "Seerr")

    init(baseURL: URL, cookie: String?) {
        self.baseURL = baseURL
        self.cookie = cookie
        self.session = Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.protocolClasses = testURLProtocolClasses + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    /// Seerr rejects loosely encoded queries (a literal space, `'`, `(`…), so
    /// everything but RFC 3986 unreserved characters is percent-encoded.
    static func encodeQuery(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: Auth

    func publicSettings() async throws -> SeerrPublicSettings {
        try decode(SeerrPublicSettings.self, from: try await send("GET", "settings/public").data)
    }

    func signInWithPlex(authToken: String) async throws -> SeerrSignIn {
        try await signIn(path: "auth/plex", body: ["authToken": authToken])
    }

    func signInLocal(email: String, password: String) async throws -> SeerrSignIn {
        try await signIn(path: "auth/local", body: ["email": email, "password": password])
    }

    func currentUser() async throws -> SeerrUser {
        try decode(SeerrUser.self, from: try await send("GET", "auth/me").data)
    }

    /// Best effort: the local sign-out happens whatever the server says.
    func logout() async {
        _ = try? await send("POST", "auth/logout", body: Data("{}".utf8))
    }

    // MARK: Browse

    func search(query: String, page: Int = 1) async throws -> SeerrSearchPage {
        let raw = "query=\(Self.encodeQuery(query))&page=\(page)"
        return try decode(SeerrSearchPage.self, from: try await send("GET", "search", rawQuery: raw).data)
    }

    func details(kind: SeerrMediaKind, tmdbId: Int) async throws -> SeerrTitleDetails {
        try decode(SeerrTitleDetails.self, from: try await send("GET", "\(kind.rawValue)/\(tmdbId)").data)
    }

    // MARK: Requests

    func requestMovie(tmdbId: Int) async throws -> SeerrRequest {
        let body = RequestBody(mediaType: SeerrMediaKind.movie.rawValue, mediaId: tmdbId, seasons: nil)
        return try decode(SeerrRequest.self, from: try await send("POST", "request", body: try JSONEncoder().encode(body)).data)
    }

    /// Never season 0: specials are off on the server and never offered.
    func requestShow(tmdbId: Int, seasons: [Int]) async throws -> SeerrRequest {
        let numbers = Array(Set(seasons.filter { $0 > 0 })).sorted()
        guard !numbers.isEmpty else { throw SeerrError.nothingToRequest }
        let body = RequestBody(mediaType: SeerrMediaKind.tv.rawValue, mediaId: tmdbId, seasons: numbers)
        return try decode(SeerrRequest.self, from: try await send("POST", "request", body: try JSONEncoder().encode(body)).data)
    }

    /// The person's own requests, newest first.
    func requests(requestedBy userId: Int, take: Int = 50) async throws -> [SeerrRequest] {
        let raw = "take=\(take)&skip=0&sort=added&requestedBy=\(userId)"
        return try decode(SeerrRequestPage.self, from: try await send("GET", "request", rawQuery: raw).data).results
    }

    /// Seerr only lets the requester cancel while it's still pending;
    /// MANAGE_REQUESTS can delete any request (`DELETE /request/{id}`).
    func cancelRequest(id: Int) async throws {
        _ = try await send("DELETE", "request/\(id)")
    }

    /// One page of `GET /request`, newest first. Without `requestedBy` the
    /// server lists everyone's for MANAGE_REQUESTS / REQUEST_VIEW and only
    /// the caller's for anyone else.
    func requestPage(filter: SeerrRequestFilter, take: Int, skip: Int, requestedBy userId: Int?) async throws -> SeerrRequestPage {
        var raw = "take=\(take)&skip=\(skip)&filter=\(filter.rawValue)&sort=added&sortDirection=desc"
        if let userId { raw += "&requestedBy=\(userId)" }
        return try decode(SeerrRequestPage.self, from: try await send("GET", "request", rawQuery: raw).data)
    }

    /// MANAGE_REQUESTS only, and only while the request is pending (409 after).
    func approveRequest(id: Int) async throws -> SeerrRequest {
        try decode(SeerrRequest.self, from: try await send("POST", "request/\(id)/approve", body: Data("{}".utf8)).data)
    }

    func declineRequest(id: Int) async throws -> SeerrRequest {
        try decode(SeerrRequest.self, from: try await send("POST", "request/\(id)/decline", body: Data("{}".utf8)).data)
    }

    /// Every request on the server, by state.
    func requestCount() async throws -> SeerrRequestCount {
        try decode(SeerrRequestCount.self, from: try await send("GET", "request/count").data)
    }

    /// The person's own request limits (someone else's needs MANAGE_USERS
    /// and MANAGE_REQUESTS).
    func quota(userId: Int) async throws -> SeerrQuota {
        try decode(SeerrQuota.self, from: try await send("GET", "user/\(userId)/quota").data)
    }

    // MARK: Discover

    /// One page of a Discover row. Recent Requests is not a discover route
    /// (see `requestPage`); asking for it is an error.
    func discover(_ slider: SeerrDiscoverSlider, page: Int = 1) async throws -> SeerrSearchPage {
        guard let path = slider.path else { throw SeerrError.invalidServerURL }
        return try decode(SeerrSearchPage.self, from: try await send("GET", path, rawQuery: "page=\(page)").data)
    }

    // MARK: Plumbing

    private struct RequestBody: Encodable {
        let mediaType: String
        let mediaId: Int
        let seasons: [Int]?
    }

    private struct ErrorBody: Decodable {
        let message: String?
        let error: String?
    }

    private func signIn(path: String, body: [String: String]) async throws -> SeerrSignIn {
        let (data, response) = try await send("POST", path, body: try JSONEncoder().encode(body), isSignIn: true)
        guard let cookie = Self.sessionCookie(from: response) else { throw SeerrError.noSession }
        let user = try decode(SeerrUser.self, from: data)
        self.cookie = cookie
        return SeerrSignIn(user: user, cookie: cookie)
    }

    /// `connect.sid=<value>` from the response's Set-Cookie, attributes dropped.
    static func sessionCookie(from response: HTTPURLResponse) -> String? {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        guard let url = response.url else { return nil }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard let session = cookies.first(where: { $0.name == sessionCookieName }), !session.value.isEmpty else {
            return nil
        }
        return "\(session.name)=\(session.value)"
    }

    private func url(for path: String, rawQuery: String?) throws -> URL {
        let api = baseURL.appendingPathComponent("api/v1").appendingPathComponent(path)
        guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false) else {
            throw SeerrError.invalidServerURL
        }
        components.percentEncodedQuery = rawQuery
        guard let url = components.url else { throw SeerrError.invalidServerURL }
        return url
    }

    private func send(
        _ method: String,
        _ path: String,
        rawQuery: String? = nil,
        body: Data? = nil,
        isSignIn: Bool = false
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: try url(for: path, rawQuery: rawQuery))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie, !isSignIn {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            logger.error("Seerr \(method, privacy: .public) \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw SeerrError.network("Couldn't reach the request server.")
        }
        guard let http = response as? HTTPURLResponse else { throw SeerrError.decoding }
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401, 403:
            throw isSignIn ? SeerrError.invalidCredentials : SeerrError.unauthorized
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data)).flatMap { $0.message ?? $0.error }
            logger.error("Seerr \(method, privacy: .public) \(path, privacy: .public) answered \(http.statusCode, privacy: .public)")
            throw SeerrError.server(status: http.statusCode, message: message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("Seerr response didn't decode as \(String(describing: type), privacy: .public)")
            throw SeerrError.decoding
        }
    }
}

/// Plex's PIN sign-in (what the Plex apps use): the TV shows a short code for
/// plex.tv/link, the phone opens Plex's sign-in page; either way the PIN is
/// polled until it carries the person's Plex token, which is handed to Seerr
/// once and never stored.
struct PlexPinClient: Sendable {
    let clientIdentifier: String
    private let session: URLSession

    static let product = "Sashimi"
    private static let pinsURL = URL(string: "https://plex.tv/api/v2/pins")

    init(clientIdentifier: String) {
        self.clientIdentifier = clientIdentifier
        self.session = SeerrClient.makeSession()
    }

    func createPin(strong: Bool) async throws -> PlexPin {
        guard let base = Self.pinsURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw SeerrError.invalidServerURL
        }
        components.percentEncodedQuery = "strong=\(strong)"
        guard let url = components.url else { throw SeerrError.invalidServerURL }
        return try await send(url: url, method: "POST")
    }

    func checkPin(id: Int) async throws -> PlexPin {
        guard let url = Self.pinsURL?.appendingPathComponent(String(id)) else { throw SeerrError.invalidServerURL }
        return try await send(url: url, method: "GET")
    }

    /// Plex's own sign-in page for a strong PIN, the way Seerr's website
    /// opens it: no `forwardUrl`. Plex's page only forwards to Plex's own app
    /// schemes (`plex:`, `plexamp-auth:`…) or to http(s); anything else, such
    /// as `sashimi://`, makes it leave for watch.plex.tv straight away without
    /// linking the PIN. The app polls the PIN and closes the page itself.
    static func webSignInURL(clientIdentifier: String, code: String) -> URL {
        let params: [(String, String)] = [
            ("clientID", clientIdentifier),
            ("code", code),
            ("context[device][product]", product)
        ]
        let query = params
            .map { "\(SeerrClient.encodeQuery($0.0))=\(SeerrClient.encodeQuery($0.1))" }
            .joined(separator: "&")
        // A literal fragment ("#!?…") that URLComponents would re-encode.
        return URL(string: "https://app.plex.tv/auth/#!?\(query)") ?? URL(fileURLWithPath: "/")
    }

    private func send(url: URL, method: String) async throws -> PlexPin {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                         forHTTPHeaderField: "X-Plex-Version")
        #if os(tvOS)
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("Sashimi (Apple TV)", forHTTPHeaderField: "X-Plex-Device-Name")
        #else
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("Sashimi (iPhone/iPad)", forHTTPHeaderField: "X-Plex-Device-Name")
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SeerrError.network("Couldn't reach plex.tv.")
        }
        guard let http = response as? HTTPURLResponse else { throw SeerrError.decoding }
        guard (200..<300).contains(http.statusCode) else {
            throw SeerrError.server(status: http.statusCode, message: nil)
        }
        guard let pin = try? JSONDecoder().decode(PlexPin.self, from: data) else { throw SeerrError.decoding }
        return pin
    }
}
