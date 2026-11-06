#if DEBUG
import Foundation

/// Debug builds only: `SASHIMI_SEERR_DEMO=<screen>` opens one of the request
/// screens against a canned Seerr ("seerr.demo") answered in-process, so the
/// screens can be looked at and screenshotted in a simulator without a
/// Jellyfin or Seerr account. Nothing is sent anywhere; requests and cancels
/// are answered locally and change nothing.
enum SeerrDemo {
    static var screen: String? {
        ProcessInfo.processInfo.environment["SASHIMI_SEERR_DEMO"]
    }

    /// Points the shared session at the canned server and, unless the
    /// screen is the signed-out Settings one, signs in as a demo user.
    @MainActor
    static func start(signedIn: Bool) async {
        SeerrClient.testURLProtocolClasses = [SeerrDemoServer.self]
        _ = SeerrSession.shared.setServerAddress("https://seerr.demo")
        await SeerrSession.shared.refreshPublicSettings()
        if signedIn {
            await SeerrSession.shared.signInLocal(email: "mom@example.com", password: "demo")
        }
    }
}

final class SeerrDemoServer: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        ["seerr.demo", "plex.tv"].contains(request.url?.host ?? "")
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let route = "\(request.httpMethod ?? "GET") \(url.path)"
        var headers = ["Content-Type": "application/json"]
        let (status, body) = Self.answer(route)
        if route == "POST /api/v1/auth/local" {
            headers["Set-Cookie"] = "connect.sid=demo; Path=/; HttpOnly"
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return ISO8601DateFormatter().string(from: date)
    }

    private static let movies: [String: String] = [
        "GET /api/v1/movie/841": "{\"id\":841,\"title\":\"Dune\",\"releaseDate\":\"1984-12-14\",\"mediaInfo\":{\"status\":2}}",
        "GET /api/v1/movie/251": "{\"id\":251,\"title\":\"Jodorowsky's Dune\",\"releaseDate\":\"2013-05-01\",\"mediaInfo\":{\"status\":3}}",
        "GET /api/v1/movie/252": "{\"id\":252,\"title\":\"Dune Drifter\",\"releaseDate\":\"2020-10-01\"}",
        "GET /api/v1/movie/253": "{\"id\":253,\"title\":\"Wicked: For Good\",\"releaseDate\":\"2025-11-21\",\"mediaInfo\":{\"status\":5}}"
    ]

    private static func answer(_ route: String) -> (Int, String) {
        let user = "{\"id\":7,\"displayName\":\"mom\",\"email\":\"mom@example.com\"}"
        if let movie = movies[route] { return (200, movie) }
        switch route {
        case "GET /api/v1/settings/public":
            return (200, "{\"applicationTitle\":\"MondoVision\",\"localLogin\":true,\"partialRequestsEnabled\":true}")
        case "POST /api/v1/auth/local", "GET /api/v1/auth/me":
            return (200, user)
        case "POST /api/v1/auth/logout":
            return (200, "{\"status\":\"ok\"}")
        case "POST /api/v2/pins":
            return (201, "{\"id\":1,\"code\":\"K7QF\"}")
        case "GET /api/v2/pins/1":
            return (200, "{\"id\":1,\"code\":\"K7QF\",\"authToken\":null}")
        case "GET /api/v1/search":
            return (200, """
            {"page":1,"totalPages":1,"results":[
              {"id":438631,"mediaType":"movie","title":"Dune","releaseDate":"2021-09-15","mediaInfo":{"status":5}},
              {"id":90228,"mediaType":"tv","name":"Dune: Prophecy","firstAirDate":"2024-11-17"},
              {"id":841,"mediaType":"movie","title":"Dune","releaseDate":"1984-12-14","mediaInfo":{"status":2}},
              {"id":251,"mediaType":"movie","title":"Jodorowsky's Dune","releaseDate":"2013-05-01","mediaInfo":{"status":3}},
              {"id":252,"mediaType":"movie","title":"Dune Drifter","releaseDate":"2020-10-01",
               "mediaInfo":{"status":1,"requests":[{"id":9,"status":3,"requestedBy":{"id":7}}]}},
              {"id":1,"mediaType":"person","name":"Denis Villeneuve"}
            ]}
            """)
        case "GET /api/v1/tv/90228":
            return (200, """
            {"id":90228,"name":"Dune: Prophecy","firstAirDate":"2024-11-17","status":"Returning Series",
             "overview":"Ten thousand years before the ascension of Paul Atreides, two Harkonnen sisters combat forces that threaten the future of humankind, and establish the fabled sect that will become known as the Bene Gesserit.",
             "genres":[{"name":"Sci-Fi & Fantasy"},{"name":"Drama"}],
             "contentRatings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"}]},
             "relatedVideos":[{"key":"demo","site":"YouTube","type":"Trailer"}],
             "seasons":[{"seasonNumber":1,"episodeCount":6,"airDate":"2024-11-17"},{"seasonNumber":2,"episodeCount":0,"airDate":null}],
             "credits":{"cast":[{"id":1,"name":"Emily Watson","character":"Valya Harkonnen"},
               {"id":2,"name":"Olivia Williams","character":"Tula Harkonnen"},{"id":3,"name":"Travis Fimmel","character":"Desmond Hart"}]}}
            """)
        case "GET /api/v1/tv/77":
            let seasons = (1...11).map { number in
                "{\"seasonNumber\":\(number),\"episodeCount\":\(number == 10 ? 12 : 10),\"airDate\":\"20\(14 + number)-02-13\"}"
            }.joined(separator: ",")
            let statuses = (1...9).map { "{\"seasonNumber\":\($0),\"status\":5}" }.joined(separator: ",")
            return (200, "{\"id\":77,\"name\":\"Love Is Blind\",\"firstAirDate\":\"2020-02-13\",\"status\":\"Returning Series\",\"seasons\":[\(seasons)],\"mediaInfo\":{\"status\":4,\"seasons\":[\(statuses)]}}")
        case "GET /api/v1/request":
            return (200, """
            {"pageInfo":{"page":1,"pages":1,"results":4},"results":[
              {"id":1,"status":1,"type":"tv","createdAt":"\(day(0))","updatedAt":"\(day(0))","seasons":[{"seasonNumber":1,"status":1}],
               "media":{"tmdbId":90228,"mediaType":"tv","status":2},"requestedBy":{"id":7}},
              {"id":2,"status":2,"type":"movie","createdAt":"\(day(-4))","updatedAt":"\(day(-3))",
               "media":{"tmdbId":251,"mediaType":"movie","status":3,"downloadStatus":[{"size":100,"sizeLeft":38}]},"requestedBy":{"id":7}},
              {"id":3,"status":2,"type":"movie","createdAt":"\(day(-6))","updatedAt":"\(day(-5))",
               "media":{"tmdbId":253,"mediaType":"movie","status":5,"mediaAddedAt":"\(day(-1))"},"requestedBy":{"id":7}},
              {"id":4,"status":3,"type":"movie","createdAt":"\(day(-20))","updatedAt":"\(day(-19))",
               "media":{"tmdbId":252,"mediaType":"movie","status":1},"requestedBy":{"id":7}}
            ]}
            """)
        default:
            if route.hasPrefix("DELETE /api/v1/request/") { return (204, "") }
            if route == "POST /api/v1/request" { return (201, "{\"id\":99,\"status\":1}") }
            return (404, "{\"message\":\"Not in the demo\"}")
        }
    }
}
#endif
