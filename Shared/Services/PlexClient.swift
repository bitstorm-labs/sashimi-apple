import Foundation

// swiftlint:disable type_body_length file_length
// PlexClient handles all Plex API endpoints - splitting would fragment the API layer

// MARK: - Plex API Models

struct PlexPin: Codable {
    let id: Int
    let code: String
    let authToken: String?

    enum CodingKeys: String, CodingKey {
        case id, code, authToken
    }
}

struct PlexResource: Codable {
    let name: String
    let provides: String
    let clientIdentifier: String
    let connections: [PlexConnection]
}

struct PlexConnection: Codable {
    let uri: String
    let local: Bool
}

struct PlexLibrary: Codable {
    let key: String
    let title: String
    let type: String // "movie", "show", "artist"
}

struct PlexMetadata: Codable {
    let ratingKey: String
    let key: String
    let type: String // "movie", "show", "season", "episode"
    let title: String
    let summary: String?
    let year: Int?
    let duration: Int? // milliseconds
    let viewOffset: Int? // resume position in milliseconds
    let viewCount: Int?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let grandparentTitle: String?
    let parentIndex: Int?
    let index: Int?
    let audienceRating: Double?
    let contentRating: String?
    let Genre: [PlexTag]? // swiftlint:disable:this identifier_name
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let Media: [PlexMedia]? // swiftlint:disable:this identifier_name

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, summary, year, duration
        case viewOffset, viewCount
        case parentRatingKey, grandparentRatingKey, grandparentTitle
        case parentIndex, index
        case audienceRating, contentRating
        case Genre, thumb, art, parentThumb, grandparentThumb, Media
    }
}

struct PlexTag: Codable {
    let tag: String
}

struct PlexMedia: Codable {
    let id: Int
    let duration: Int?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    let audioChannels: Int?
    let Part: [PlexPart]? // swiftlint:disable:this identifier_name

    enum CodingKeys: String, CodingKey {
        case id, duration, container, videoCodec, audioCodec
        case videoResolution, audioChannels, Part
    }
}

struct PlexPart: Codable {
    let id: Int
    let key: String
    let container: String?
    let duration: Int?
    let Stream: [PlexStream]? // swiftlint:disable:this identifier_name

    enum CodingKeys: String, CodingKey {
        case id, key, container, duration, Stream
    }
}

struct PlexStream: Codable {
    let id: Int
    let streamType: Int // 1=video, 2=audio, 3=subtitle
    let codec: String?
    let language: String?
    let displayTitle: String?
    let channels: Int?
    let selected: Bool?
    let index: Int?
}

// MARK: - Plex JSON Response Wrappers

/// Top-level wrapper for all Plex JSON responses
private struct PlexMediaContainer<T: Codable>: Codable {
    let MediaContainer: PlexContainer<T> // swiftlint:disable:this identifier_name
}

private struct PlexContainer<T: Codable>: Codable {
    let size: Int?
    let totalSize: Int?
    let Metadata: T? // swiftlint:disable:this identifier_name
    let Directory: T? // swiftlint:disable:this identifier_name
    let Hub: [PlexHub]? // swiftlint:disable:this identifier_name
}

private struct PlexHub: Codable {
    let type: String?
    let Metadata: [PlexMetadata]? // swiftlint:disable:this identifier_name
}

// MARK: - Plex Error

enum PlexError: LocalizedError {
    case notConfigured
    case invalidResponse
    case invalidURL
    case httpError(statusCode: Int)
    case decodingError
    case pinNotAuthorized

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Plex client is not configured"
        case .invalidResponse: return "Invalid response from Plex server"
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP error \(code)"
        case .decodingError: return "Failed to decode Plex response"
        case .pinNotAuthorized: return "PIN has not been authorized yet"
        }
    }
}

// MARK: - Plex Client

actor PlexClient {
    private var serverURL: URL?
    private var authToken: String?

    private let clientIdentifier: String
    private let urlSession: URLSession

    init() {
        if let stored = UserDefaults.standard.string(forKey: "plexClientIdentifier") {
            self.clientIdentifier = stored
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "plexClientIdentifier")
            self.clientIdentifier = newId
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.urlCache = nil
        self.urlSession = URLSession(configuration: config)
    }

    func configure(serverURL: URL?, authToken: String?) {
        self.serverURL = serverURL
        self.authToken = authToken
    }

    var isConfigured: Bool {
        serverURL != nil && authToken != nil
    }

    // MARK: - Plex Headers

    private var plexHeaders: [(String, String)] {
        var headers: [(String, String)] = [
            ("X-Plex-Client-Identifier", clientIdentifier),
            ("X-Plex-Product", "Sashimi"),
            ("X-Plex-Version", "1.0"),
            ("X-Plex-Platform", "tvOS"),
            ("X-Plex-Device", "Apple TV"),
            ("Accept", "application/json")
        ]
        if let token = authToken {
            headers.append(("X-Plex-Token", token))
        }
        return headers
    }

    private func applyPlexHeaders(to request: inout URLRequest) {
        for (key, value) in plexHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    // MARK: - Generic Request

    private func request(
        baseURL: URL? = nil,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        let base = baseURL ?? serverURL
        guard let base else {
            throw PlexError.notConfigured
        }

        guard var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw PlexError.invalidURL
        }

        if let queryItems, !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }

        guard let url = components.url else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyPlexHeaders(to: &request)

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let body {
            request.httpBody = body
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw PlexError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    // MARK: - PIN Auth Flow

    /// Request a new PIN for device linking at https://plex.tv/link
    func requestPin() async throws -> PlexPin {
        let plexTV = URL(string: "https://plex.tv")!
        let bodyString = "strong=true&X-Plex-Product=Sashimi&X-Plex-Client-Identifier=\(clientIdentifier)"
        let bodyData = bodyString.data(using: .utf8)

        let data = try await request(
            baseURL: plexTV,
            path: "/api/v2/pins",
            method: "POST",
            body: bodyData,
            contentType: "application/x-www-form-urlencoded"
        )

        do {
            let pin = try JSONDecoder().decode(PlexPin.self, from: data)
            return pin
        } catch {
            throw PlexError.decodingError
        }
    }

    /// Check if a PIN has been authorized by the user
    func checkPin(pinId: Int) async throws -> PlexPin {
        let plexTV = URL(string: "https://plex.tv")!

        let data = try await request(
            baseURL: plexTV,
            path: "/api/v2/pins/\(pinId)"
        )

        do {
            let pin = try JSONDecoder().decode(PlexPin.self, from: data)
            return pin
        } catch {
            throw PlexError.decodingError
        }
    }

    /// Get available Plex servers for the authenticated user
    func getServers(token: String) async throws -> [PlexResource] {
        let plexTV = URL(string: "https://plex.tv")!

        // Temporarily set token for this request
        let previousToken = authToken
        authToken = token
        defer { authToken = previousToken }

        let data = try await request(
            baseURL: plexTV,
            path: "/api/v2/resources",
            queryItems: [URLQueryItem(name: "includeRelay", value: "1")]
        )

        do {
            let resources = try JSONDecoder().decode([PlexResource].self, from: data)
            return resources.filter { $0.provides.contains("server") }
        } catch {
            throw PlexError.decodingError
        }
    }

    // MARK: - Library API

    func getLibraries() async throws -> [PlexLibrary] {
        let data = try await request(path: "/library/sections")

        struct LibraryResponse: Codable {
            let MediaContainer: LibraryContainer // swiftlint:disable:this identifier_name

            struct LibraryContainer: Codable {
                let Directory: [PlexLibrary]? // swiftlint:disable:this identifier_name
            }
        }

        do {
            let response = try JSONDecoder().decode(LibraryResponse.self, from: data)
            return response.MediaContainer.Directory ?? []
        } catch {
            throw PlexError.decodingError
        }
    }

    // MARK: - Item API

    func getLibraryItems(
        sectionKey: String,
        sort: String? = nil,
        start: Int? = nil,
        size: Int? = nil
    ) async throws -> (items: [PlexMetadata], totalSize: Int) {
        var queryItems: [URLQueryItem] = []
        if let sort {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }
        if let start {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"))
        }
        if let size {
            queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"))
        }

        let data = try await request(
            path: "/library/sections/\(sectionKey)/all",
            queryItems: queryItems.isEmpty ? nil : queryItems
        )

        do {
            let response = try JSONDecoder().decode(
                PlexMediaContainer<[PlexMetadata]>.self,
                from: data
            )
            let items = response.MediaContainer.Metadata ?? []
            let total = response.MediaContainer.totalSize ?? response.MediaContainer.size ?? items.count
            return (items, total)
        } catch {
            throw PlexError.decodingError
        }
    }

    func getItem(ratingKey: String) async throws -> PlexMetadata {
        let data = try await request(path: "/library/metadata/\(ratingKey)")

        do {
            let response = try JSONDecoder().decode(
                PlexMediaContainer<[PlexMetadata]>.self,
                from: data
            )
            guard let item = response.MediaContainer.Metadata?.first else {
                throw PlexError.invalidResponse
            }
            return item
        } catch let error as PlexError {
            throw error
        } catch {
            throw PlexError.decodingError
        }
    }

    func getChildren(ratingKey: String) async throws -> [PlexMetadata] {
        let data = try await request(path: "/library/metadata/\(ratingKey)/children")

        do {
            let response = try JSONDecoder().decode(
                PlexMediaContainer<[PlexMetadata]>.self,
                from: data
            )
            return response.MediaContainer.Metadata ?? []
        } catch {
            throw PlexError.decodingError
        }
    }

    func getOnDeck() async throws -> [PlexMetadata] {
        let data = try await request(path: "/library/onDeck")

        do {
            let response = try JSONDecoder().decode(
                PlexMediaContainer<[PlexMetadata]>.self,
                from: data
            )
            return response.MediaContainer.Metadata ?? []
        } catch {
            throw PlexError.decodingError
        }
    }

    func getRecentlyAdded(sectionKey: String? = nil, limit: Int = 20) async throws -> [PlexMetadata] {
        let path: String
        if let sectionKey {
            path = "/library/sections/\(sectionKey)/recentlyAdded"
        } else {
            path = "/library/recentlyAdded"
        }

        let data = try await request(
            path: path,
            queryItems: [URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")]
        )

        do {
            let response = try JSONDecoder().decode(
                PlexMediaContainer<[PlexMetadata]>.self,
                from: data
            )
            return response.MediaContainer.Metadata ?? []
        } catch {
            throw PlexError.decodingError
        }
    }

    func search(query: String) async throws -> [PlexMetadata] {
        let data = try await request(
            path: "/hubs/search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "includeCollections", value: "0")
            ]
        )

        // Search returns hubs, each containing metadata
        struct SearchResponse: Codable {
            let MediaContainer: SearchContainer // swiftlint:disable:this identifier_name

            struct SearchContainer: Codable {
                let Hub: [SearchHub]? // swiftlint:disable:this identifier_name
            }

            struct SearchHub: Codable {
                let type: String?
                let Metadata: [PlexMetadata]? // swiftlint:disable:this identifier_name
            }
        }

        do {
            let response = try JSONDecoder().decode(SearchResponse.self, from: data)
            var results: [PlexMetadata] = []
            for hub in response.MediaContainer.Hub ?? [] {
                results.append(contentsOf: hub.Metadata ?? [])
            }
            return results
        } catch {
            throw PlexError.decodingError
        }
    }

    // MARK: - Playback Tracking

    func reportTimeline(
        ratingKey: String,
        state: String,
        timeMs: Int,
        durationMs: Int
    ) async throws {
        _ = try await request(
            path: "/:/timeline",
            queryItems: [
                URLQueryItem(name: "ratingKey", value: ratingKey),
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "time", value: "\(timeMs)"),
                URLQueryItem(name: "duration", value: "\(durationMs)")
            ]
        )
    }

    // MARK: - Watched State

    func scrobble(ratingKey: String) async throws {
        _ = try await request(
            path: "/:/scrobble",
            queryItems: [
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)")
            ]
        )
    }

    func unscrobble(ratingKey: String) async throws {
        _ = try await request(
            path: "/:/unscrobble",
            queryItems: [
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)")
            ]
        )
    }

    // MARK: - Image URL

    /// Build a Plex image transcode URL. Nonisolated so it can be called synchronously from SwiftUI views.
    nonisolated func imageURL(path: String?, maxWidth: Int = 400) -> URL? {
        guard let path, !path.isEmpty else { return nil }

        // Read server URL and token from UserDefaults for nonisolated access
        guard let serverURLString = UserDefaults.standard.string(forKey: "plexServerURL"),
              let serverURL = URL(string: serverURLString),
              let token = UserDefaults.standard.string(forKey: "plexAuthToken") else {
            return nil
        }

        guard var components = URLComponents(
            url: serverURL.appendingPathComponent("/photo/:/transcode"),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "width", value: "\(maxWidth)"),
            URLQueryItem(name: "height", value: "\(maxWidth)"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]

        return components.url
    }

    // MARK: - Stream URL

    func streamURL(partKey: String) -> URL? {
        guard let serverURL, let authToken else { return nil }

        guard var components = URLComponents(
            url: serverURL.appendingPathComponent(partKey),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]

        return components.url
    }

    // MARK: - Persistence for Nonisolated Access

    /// Persist server URL and token to UserDefaults so nonisolated image URL methods can access them.
    func persistForSync() {
        if let serverURL {
            UserDefaults.standard.set(serverURL.absoluteString, forKey: "plexServerURL")
        }
        if let authToken {
            UserDefaults.standard.set(authToken, forKey: "plexAuthToken")
        }
    }
}

// swiftlint:enable type_body_length file_length
