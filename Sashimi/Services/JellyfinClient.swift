import Foundation
import Security

// swiftlint:disable type_body_length file_length
// JellyfinClient handles all Jellyfin API endpoints - splitting would fragment the API layer

// MARK: - Certificate Trust Settings

@MainActor
class CertificateTrustSettings: ObservableObject {
    static let shared = CertificateTrustSettings()

    @Published var allowSelfSigned: Bool {
        didSet { UserDefaults.standard.set(allowSelfSigned, forKey: "allowSelfSignedCerts") }
    }
    @Published var allowExpiredCerts: Bool {
        didSet { UserDefaults.standard.set(allowExpiredCerts, forKey: "allowExpiredCerts") }
    }
    @Published var trustedHosts: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(trustedHosts), forKey: "trustedHosts")
        }
    }

    init() {
        self.allowSelfSigned = UserDefaults.standard.bool(forKey: "allowSelfSignedCerts")
        self.allowExpiredCerts = UserDefaults.standard.bool(forKey: "allowExpiredCerts")
        if let hosts = UserDefaults.standard.array(forKey: "trustedHosts") as? [String] {
            self.trustedHosts = Set(hosts)
        } else {
            self.trustedHosts = []
        }
    }

    func trustHost(_ host: String) {
        trustedHosts.insert(host)
    }

    func untrustHost(_ host: String) {
        trustedHosts.remove(host)
    }

    func isHostTrusted(_ host: String) -> Bool {
        trustedHosts.contains(host)
    }
}

// MARK: - URLSession Delegate for Certificate Validation

final class CertificateValidationDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowSelfSigned: () -> Bool
    private let allowExpired: () -> Bool
    private let isHostTrusted: (String) -> Bool

    init(
        allowSelfSigned: @escaping () -> Bool,
        allowExpired: @escaping () -> Bool,
        isHostTrusted: @escaping (String) -> Bool
    ) {
        self.allowSelfSigned = allowSelfSigned
        self.allowExpired = allowExpired
        self.isHostTrusted = isHostTrusted
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // If host is explicitly trusted, accept the certificate
        if isHostTrusted(host) {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            return
        }

        // Evaluate the certificate chain
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        if isValid {
            // Certificate is valid through system trust
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            return
        }

        // Check for recoverable errors
        if let cfError = error {
            let errorCode = CFErrorGetCode(cfError)

            // Self-signed certificate (error code 3 = kSecTrustResultRecoverableTrustFailure often)
            if allowSelfSigned() {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }

            // Expired certificate
            if allowExpired() && errorCode == errSecCertificateExpired {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }

        // Certificate validation failed
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Jellyfin Client

actor JellyfinClient {
    private var serverURL: URL?
    private var accessToken: String?
    private var userId: String?

    private let deviceId: String
    private let deviceName = "Sashimi tvOS"
    private let clientName = "Sashimi"
    private let clientVersion = "1.0.0"

    private let urlSession: URLSession
    private let certificateDelegate: CertificateValidationDelegate
    private let maxRetries = 3

    static let shared = JellyfinClient()

    private init() {
        if let stored = UserDefaults.standard.string(forKey: "deviceId") {
            self.deviceId = stored
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "deviceId")
            self.deviceId = newId
        }

        // Create certificate validation delegate
        self.certificateDelegate = CertificateValidationDelegate(
            allowSelfSigned: { UserDefaults.standard.bool(forKey: "allowSelfSignedCerts") },
            allowExpired: { UserDefaults.standard.bool(forKey: "allowExpiredCerts") },
            isHostTrusted: { host in
                if let hosts = UserDefaults.standard.array(forKey: "trustedHosts") as? [String] {
                    return hosts.contains(host)
                }
                return false
            }
        )

        // Configure URLSession with certificate validation delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.urlCache = nil  // Disable caching to ensure fresh API responses
        self.urlSession = URLSession(
            configuration: config,
            delegate: certificateDelegate,
            delegateQueue: nil
        )
    }

    func configure(serverURL: URL, accessToken: String? = nil, userId: String? = nil) {
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.userId = userId
    }

    var isConfigured: Bool {
        serverURL != nil && accessToken != nil && userId != nil
    }

    var currentUserId: String? {
        userId
    }

    var currentServerURL: URL? {
        serverURL
    }

    private var authorizationHeader: String {
        var parts = [
            "MediaBrowser Client=\"\(clientName)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(clientVersion)\""
        ]
        if let token = accessToken {
            parts.append("Token=\"\(token)\"")
        }
        return parts.joined(separator: ", ")
    }

    private func request(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        retryCount: Int = 0
    ) async throws -> Data {
        guard let serverURL else {
            throw JellyfinError.notConfigured
        }

        guard var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidURL
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
        }

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw JellyfinError.invalidResponse
            }

            // Handle 401/403 as session expiry (don't retry)
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                await SessionManager.shared.logout(reason: .sessionExpired)
                throw JellyfinError.sessionExpired
            }

            // Retry on 5xx server errors
            if (500...599).contains(httpResponse.statusCode) && retryCount < maxRetries {
                let delay = pow(2.0, Double(retryCount))
                try await Task.sleep(for: .seconds(delay))
                return try await self.request(path: path, method: method, queryItems: queryItems, body: body, retryCount: retryCount + 1)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw JellyfinError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        } catch let error as JellyfinError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Retry on network errors (URLError)
            if retryCount < maxRetries {
                let delay = pow(2.0, Double(retryCount))
                try await Task.sleep(for: .seconds(delay))
                return try await self.request(path: path, method: method, queryItems: queryItems, body: body, retryCount: retryCount + 1)
            }
            throw JellyfinError.networkError(error)
        }
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        let body = ["Username": username, "Pw": password]
        let bodyData = try JSONEncoder().encode(body)

        let data = try await request(
            path: "/Users/AuthenticateByName",
            method: "POST",
            body: bodyData
        )

        let result = try JSONDecoder().decode(AuthenticationResult.self, from: data)
        self.accessToken = result.accessToken
        self.userId = result.user.id

        return result
    }

    func getResumeItems(limit: Int = 20) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(
            path: "/Users/\(userId)/Items/Resume",
            queryItems: [
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,ParentBackdropImageTags,UserData,Path"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
                URLQueryItem(name: "Recursive", value: "true")
            ]
        )

        let response = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return response.items
    }

    func getNextUp(limit: Int = 50) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(
            path: "/Shows/NextUp",
            queryItems: [
                URLQueryItem(name: "UserId", value: userId),
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,UserData,ParentBackdropImageTags,Path"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
                URLQueryItem(name: "EnableRewatching", value: "false"),
                URLQueryItem(name: "DisableFirstEpisode", value: "false")
            ]
        )

        let response = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return response.items
    }

    func getLatestMedia(parentId: String? = nil, limit: Int = 16, includeWatched: Bool = false, collectionType: String? = nil, isYouTubeLibrary: Bool = false) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        if includeWatched {
            // Determine item types based on collection type
            let itemTypes: String
            if let collectionType = collectionType?.lowercased() {
                switch collectionType {
                case "tvshows":
                    // Fetch episodes - caller will deduplicate by series with badge counts
                    itemTypes = "Episode"
                case "movies":
                    itemTypes = "Movie"
                default:
                    itemTypes = "Movie,Series,Episode"
                }
            } else {
                itemTypes = "Movie,Series,Episode"
            }

            // Use /Items endpoint with date sorting to include watched items
            var queryItems = [
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
                URLQueryItem(name: "SortBy", value: "DateCreated,SortName"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: itemTypes)
            ]

            if let parentId {
                queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
            }

            let data = try await request(
                path: "/Users/\(userId)/Items",
                queryItems: queryItems
            )

            let response = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return response.items
        } else {
            // Use /Items/Latest which filters out watched by default
            var queryItems = [
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
            ]

            if let parentId {
                queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
            }

            let data = try await request(
                path: "/Users/\(userId)/Items/Latest",
                queryItems: queryItems
            )

            return try JSONDecoder().decode([BaseItemDto].self, from: data)
        }
    }

    func getLibraryViews() async throws -> [JellyfinLibrary] {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(path: "/Users/\(userId)/Views")
        let response = try JSONDecoder().decode(LibraryViewsResponse.self, from: data)
        return response.items
    }

    func getVirtualFolders() async throws -> [VirtualFolderInfo] {
        let data = try await request(path: "/Library/VirtualFolders")
        return try JSONDecoder().decode([VirtualFolderInfo].self, from: data)
    }

    func getItems(
        parentId: String? = nil,
        includeTypes: [ItemType]? = nil,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        limit: Int = 100,
        startIndex: Int = 0,
        // swiftlint:disable:next discouraged_optional_boolean
        isPlayed: Bool? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        isFavorite: Bool? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        isResumable: Bool? = nil
    ) async throws -> ItemsResponse {
        guard let userId else { throw JellyfinError.notConfigured }

        var queryItems = [
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)")
        ]

        if let parentId {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }

        if let types = includeTypes {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types.map(\.rawValue).joined(separator: ",")))
        }

        if let isPlayed {
            queryItems.append(URLQueryItem(name: "IsPlayed", value: isPlayed ? "true" : "false"))
        }

        if let isFavorite, isFavorite {
            queryItems.append(URLQueryItem(name: "IsFavorite", value: "true"))
        }

        if let isResumable, isResumable {
            queryItems.append(URLQueryItem(name: "Filters", value: "IsResumable"))
        }

        let data = try await request(
            path: "/Users/\(userId)/Items",
            queryItems: queryItems
        )

        return try JSONDecoder().decode(ItemsResponse.self, from: data)
    }

    func getPlaybackInfo(itemId: String, maxBitrate: Int? = nil) async throws -> PlaybackInfoResponse {
        guard let userId else { throw JellyfinError.notConfigured }

        // Default to 120 Mbps (essentially unlimited), or use specified bitrate
        let streamingBitrate = maxBitrate ?? 120_000_000

        let deviceProfile: [String: Any] = [
            "MaxStreamingBitrate": streamingBitrate,
            "MaxStaticBitrate": 100000000,
            "MusicStreamingTranscodingBitrate": 384000,
            "DirectPlayProfiles": [
                ["Container": "mp4,m4v", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"],
                ["Container": "mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"]
            ],
            "TranscodingProfiles": [
                [
                    "Container": "ts",
                    "Type": "Video",
                    "VideoCodec": "h264",
                    "AudioCodec": "aac,ac3",
                    "Protocol": "hls",
                    "Context": "Streaming",
                    "MaxAudioChannels": "6",
                    "MinSegments": "2",
                    "BreakOnNonKeyFrames": true
                ]
            ],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": [
                ["Format": "vtt", "Method": "External"],
                ["Format": "srt", "Method": "External"]
            ]
        ]

        let body: [String: Any] = [
            "UserId": userId,
            "DeviceProfile": deviceProfile,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let data = try await request(
            path: "/Items/\(itemId)/PlaybackInfo",
            method: "POST",
            queryItems: [URLQueryItem(name: "UserId", value: userId)],
            body: bodyData
        )

        return try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
    }

    func buildURL(path: String) -> URL? {
        guard let serverURL else { return nil }
        let baseURL = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: baseURL + fullPath)
    }

    func getPlaybackURL(itemId: String, mediaSourceId: String, container: String? = nil) -> URL? {
        guard let serverURL, let accessToken else {
            return nil
        }

        var components = URLComponents(string: serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

        let ext = container ?? "mp4"
        components?.path += "/Videos/\(itemId)/stream.\(ext)"
        components?.queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "Container", value: ext),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId)
        ]

        return components?.url
    }

    /// Get HLS transcoding URL with optional subtitle track
    func getHLSStreamURL(itemId: String, mediaSourceId: String, subtitleStreamIndex: Int? = nil) -> URL? {
        guard let serverURL, let accessToken else {
            return nil
        }

        var components = URLComponents(string: serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        components?.path += "/Videos/\(itemId)/master.m3u8"

        var queryItems = [
            URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "TranscodingMaxAudioChannels", value: "6"),
            URLQueryItem(name: "SegmentContainer", value: "ts"),
            URLQueryItem(name: "MinSegments", value: "2"),
            URLQueryItem(name: "BreakOnNonKeyFrames", value: "true"),
            URLQueryItem(name: "TranscodeReasons", value: "SubtitleCodecNotSupported")
        ]

        if let subIndex = subtitleStreamIndex {
            queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: "\(subIndex)"))
            queryItems.append(URLQueryItem(name: "SubtitleMethod", value: "Hls"))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    func imageURL(itemId: String, imageType: String = "Primary", maxWidth: Int = 400) -> URL? {
        guard let serverURL else { return nil }

        guard var components = URLComponents(url: serverURL.appendingPathComponent("/Items/\(itemId)/Images/\(imageType)"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)")
        ]

        return components.url
    }

    nonisolated func userImageURL(userId: String, maxWidth: Int = 100) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
              let url = URL(string: serverURL) else { return nil }

        guard var components = URLComponents(url: url.appendingPathComponent("/Users/\(userId)/Images/Primary"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)")
        ]

        return components.url
    }

    nonisolated func personImageURL(personId: String, maxWidth: Int = 150) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
              let url = URL(string: serverURL) else { return nil }

        guard var components = URLComponents(url: url.appendingPathComponent("/Items/\(personId)/Images/Primary"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)")
        ]

        return components.url
    }

    /// Synchronous image URL builder - uses cached server URL from UserDefaults
    nonisolated func syncImageURL(itemId: String, imageType: String = "Primary", maxWidth: Int = 400) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
              let url = URL(string: serverURL) else { return nil }

        guard var components = URLComponents(url: url.appendingPathComponent("/Items/\(itemId)/Images/\(imageType)"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)")
        ]

        return components.url
    }

    func reportPlaybackStart(itemId: String, positionTicks: Int64 = 0) async throws {
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": false,
            "PlayMethod": "DirectStream"
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        _ = try await request(
            path: "/Sessions/Playing",
            method: "POST",
            body: bodyData
        )
    }

    func reportPlaybackProgress(itemId: String, positionTicks: Int64, isPaused: Bool) async throws {
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        _ = try await request(
            path: "/Sessions/Playing/Progress",
            method: "POST",
            body: bodyData
        )
    }

    func reportPlaybackStopped(itemId: String, positionTicks: Int64) async throws {
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        _ = try await request(
            path: "/Sessions/Playing/Stopped",
            method: "POST",
            body: bodyData
        )
    }

    func getSeasons(seriesId: String) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(
            path: "/Shows/\(seriesId)/Seasons",
            queryItems: [
                URLQueryItem(name: "UserId", value: userId),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio")
            ]
        )

        let response = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return response.items
    }

    func getEpisodes(seriesId: String, seasonId: String? = nil) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        var queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,ImageTags"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Thumb")
        ]

        if let seasonId {
            queryItems.append(URLQueryItem(name: "SeasonId", value: seasonId))
        }

        let data = try await request(
            path: "/Shows/\(seriesId)/Episodes",
            queryItems: queryItems
        )

        let response = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return response.items
    }

    func search(query: String, limit: Int = 50) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(
            path: "/Users/\(userId)/Items",
            queryItems: [
                URLQueryItem(name: "SearchTerm", value: query),
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,ParentBackdropImageTags,BackdropImageTags,UserData,ParentId,Path"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "Recursive", value: "true")
            ]
        )

        let response = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return response.items
    }

    func markPlayed(itemId: String) async throws {
        guard let userId else { throw JellyfinError.notConfigured }
        _ = try await request(path: "/Users/\(userId)/PlayedItems/\(itemId)", method: "POST")
    }

    func markUnplayed(itemId: String) async throws {
        guard let userId else { throw JellyfinError.notConfigured }
        _ = try await request(path: "/Users/\(userId)/PlayedItems/\(itemId)", method: "DELETE")
    }

    func markFavorite(itemId: String) async throws {
        guard let userId else { throw JellyfinError.notConfigured }
        _ = try await request(path: "/Users/\(userId)/FavoriteItems/\(itemId)", method: "POST")
    }

    func removeFavorite(itemId: String) async throws {
        guard let userId else { throw JellyfinError.notConfigured }
        _ = try await request(path: "/Users/\(userId)/FavoriteItems/\(itemId)", method: "DELETE")
    }

    func deleteItem(itemId: String) async throws {
        _ = try await request(path: "/Items/\(itemId)", method: "DELETE")
    }

    func refreshMetadata(itemId: String, replaceImages: Bool = false) async throws {
        var queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "MetadataRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "ImageRefreshMode", value: "FullRefresh")
        ]
        if replaceImages {
            queryItems.append(URLQueryItem(name: "ReplaceAllImages", value: "true"))
        }
        _ = try await request(path: "/Items/\(itemId)/Refresh", method: "POST", queryItems: queryItems)
    }

    func getItem(itemId: String) async throws -> BaseItemDto {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(
            path: "/Users/\(userId)/Items/\(itemId)",
            queryItems: [
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,People,UserData,Chapters,ParentBackdropImageTags"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
            ]
        )

        return try JSONDecoder().decode(BaseItemDto.self, from: data)
    }

    func getItemAncestors(itemId: String) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(path: "/Items/\(itemId)/Ancestors", queryItems: [
            URLQueryItem(name: "UserId", value: userId)
        ])

        return try JSONDecoder().decode([BaseItemDto].self, from: data)
    }

    /// Fetch skip segments from intro-skipper plugin
    /// Endpoint: /Episode/{itemId}/IntroSkipperSegments
    /// Response: {"Introduction": {"Start": 0, "End": 90}, "Credits": {"Start": 1200, "End": 1300}}
    func getMediaSegments(itemId: String) async throws -> [MediaSegmentDto] {
        let data = try await request(path: "/Episode/\(itemId)/IntroSkipperSegments")

        // Parse the dictionary response from intro-skipper
        let segmentsDict = try JSONDecoder().decode([String: IntroSkipperSegment].self, from: data)

        return segmentsDict.compactMap { key, segment in
            let segmentType = MediaSegmentType(rawValue: key) ?? .unknown
            return MediaSegmentDto(
                id: "\(itemId)-\(key)",
                type: segmentType,
                startSeconds: segment.start,
                endSeconds: segment.end
            )
        }
    }
}

enum JellyfinError: LocalizedError {
    case notConfigured
    case invalidResponse
    case invalidURL
    case httpError(statusCode: Int)
    case decodingError
    case sessionExpired
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Not connected to a server. Please sign in."
        case .invalidResponse:
            return "The server returned an unexpected response. Try again."
        case .invalidURL:
            return "Could not connect to the server. Check server address."
        case .httpError(let code):
            switch code {
            case 401, 403:
                return "Session expired. Please sign in again."
            case 404:
                return "Content not found. It may have been removed."
            case 500...599:
                return "Server is having issues. Try again later."
            default:
                return "Something went wrong. Please try again."
            }
        case .decodingError:
            return "Could not load content. Try again."
        case .sessionExpired:
            return "Session expired. Please sign in again."
        case .networkError:
            return "No internet connection. Check your network."
        }
    }
}
