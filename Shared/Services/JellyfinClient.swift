import Foundation
import Security
import CryptoKit
import os

// swiftlint:disable type_body_length file_length
// JellyfinClient handles all Jellyfin API endpoints - splitting would fragment the API layer

// MARK: - Certificate Trust Settings

/// UserDefaults keys shared between the main-actor settings object and the
/// (background-queue) URLSession certificate delegate.
enum CertificateTrustKeys {
    static let selfSignedHosts = "selfSignedAllowedHosts"
    static let expiredHosts = "expiredAllowedHosts"
    static let trustedHosts = "trustedHosts"
    static let fingerprints = "trustedHostCertFingerprints"
    // Older builds stored the allowances as single global Bools that applied
    // to every host. These keys only exist until migration runs.
    static let legacySelfSigned = "allowSelfSignedCerts"
    static let legacyExpired = "allowExpiredCerts"
}

@MainActor
class CertificateTrustSettings: ObservableObject {
    static let shared = CertificateTrustSettings()

    /// Hosts allowed to present certificates that fail system trust because
    /// of an unknown (self-signed) root.
    @Published var selfSignedAllowedHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(selfSignedAllowedHosts), forKey: CertificateTrustKeys.selfSignedHosts) }
    }
    /// Hosts allowed to present expired certificates.
    @Published var expiredAllowedHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(expiredAllowedHosts), forKey: CertificateTrustKeys.expiredHosts) }
    }
    /// Manually trusted hosts. These are pinned to the SHA-256 fingerprint of
    /// the leaf certificate they present on first acceptance.
    @Published var trustedHosts: Set<String> {
        didSet { UserDefaults.standard.set(Array(trustedHosts), forKey: CertificateTrustKeys.trustedHosts) }
    }

    /// Host of the currently configured server; the per-host toggles in the
    /// Settings UI apply to this host.
    var currentHost: String? {
        UserDefaults.standard.string(forKey: "serverURL")
            .flatMap { URL(string: $0) }?
            .host
    }

    /// Whether the current server's host may use a self-signed certificate.
    /// (Settings-UI convenience over the per-host set.)
    var allowSelfSigned: Bool {
        get {
            guard let host = currentHost else { return false }
            return selfSignedAllowedHosts.contains(host)
        }
        set {
            guard let host = currentHost else { return }
            if newValue {
                selfSignedAllowedHosts.insert(host)
            } else {
                selfSignedAllowedHosts.remove(host)
            }
        }
    }

    /// Whether the current server's host may use an expired certificate.
    var allowExpiredCerts: Bool {
        get {
            guard let host = currentHost else { return false }
            return expiredAllowedHosts.contains(host)
        }
        set {
            guard let host = currentHost else { return }
            if newValue {
                expiredAllowedHosts.insert(host)
            } else {
                expiredAllowedHosts.remove(host)
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.selfSignedAllowedHosts = Set((defaults.array(forKey: CertificateTrustKeys.selfSignedHosts) as? [String]) ?? [])
        self.expiredAllowedHosts = Set((defaults.array(forKey: CertificateTrustKeys.expiredHosts) as? [String]) ?? [])
        self.trustedHosts = Set((defaults.array(forKey: CertificateTrustKeys.trustedHosts) as? [String]) ?? [])
        migrateLegacyGlobalFlags()
    }

    /// Folds the old global allow-flags into the current server's host (the
    /// only server the app can have been talking to) so existing connections
    /// keep working, then clears them. If no server is configured yet the
    /// flags stay put and CertificateValidationDelegate migrates them on the
    /// first challenge instead.
    private func migrateLegacyGlobalFlags() {
        let defaults = UserDefaults.standard
        let legacySelfSigned = defaults.bool(forKey: CertificateTrustKeys.legacySelfSigned)
        let legacyExpired = defaults.bool(forKey: CertificateTrustKeys.legacyExpired)
        guard legacySelfSigned || legacyExpired, let host = currentHost else { return }

        if legacySelfSigned {
            selfSignedAllowedHosts.insert(host)
        }
        if legacyExpired {
            expiredAllowedHosts.insert(host)
        }
        defaults.removeObject(forKey: CertificateTrustKeys.legacySelfSigned)
        defaults.removeObject(forKey: CertificateTrustKeys.legacyExpired)
    }

    func trustHost(_ host: String) {
        trustedHosts.insert(host)
    }

    func untrustHost(_ host: String) {
        trustedHosts.remove(host)
        // Drop the pinned fingerprint so re-trusting the host later pins
        // whatever certificate it presents then.
        var pins = (UserDefaults.standard.dictionary(forKey: CertificateTrustKeys.fingerprints) as? [String: String]) ?? [:]
        pins.removeValue(forKey: host)
        UserDefaults.standard.set(pins, forKey: CertificateTrustKeys.fingerprints)
    }

    func isHostTrusted(_ host: String) -> Bool {
        trustedHosts.contains(host)
    }
}

// MARK: - URLSession Delegate for Certificate Validation

final class CertificateValidationDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowSelfSigned: (String) -> Bool
    private let allowExpired: (String) -> Bool
    private let isHostTrusted: (String) -> Bool
    private let pinnedFingerprint: (String) -> String?
    private let storePinnedFingerprint: (String, String) -> Void
    private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "CertificateValidation")

    init(
        allowSelfSigned: @escaping (String) -> Bool,
        allowExpired: @escaping (String) -> Bool,
        isHostTrusted: @escaping (String) -> Bool,
        pinnedFingerprint: @escaping (String) -> String?,
        storePinnedFingerprint: @escaping (String, String) -> Void
    ) {
        self.allowSelfSigned = allowSelfSigned
        self.allowExpired = allowExpired
        self.isHostTrusted = isHostTrusted
        self.pinnedFingerprint = pinnedFingerprint
        self.storePinnedFingerprint = storePinnedFingerprint
    }

    /// Per-host allowance lookup with legacy fallback: if the old global Bool
    /// is still set (settings object never initialized to migrate it), honor
    /// it once and migrate it to this host so it becomes host-scoped.
    static func hostAllowance(host: String, listKey: String, legacyKey: String) -> Bool {
        let defaults = UserDefaults.standard
        var hosts = (defaults.array(forKey: listKey) as? [String]) ?? []
        if hosts.contains(host) {
            return true
        }
        if defaults.bool(forKey: legacyKey) {
            hosts.append(host)
            defaults.set(hosts, forKey: listKey)
            defaults.removeObject(forKey: legacyKey)
            return true
        }
        return false
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

        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        // Manually trusted hosts are accepted only while they present the
        // leaf certificate pinned when the host was first accepted —
        // trusting a host is not a blanket pass for whatever cert appears.
        if isHostTrusted(host) {
            if leafMatchesPin(serverTrust, host: host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        if isValid {
            // Certificate chain is valid through system trust
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // Classify the failure by error domain + Security framework codes.
        // (The old check compared SecTrustResultType constants (3, 5) against
        // CFError codes, which are OSStatus values — they never matched.)
        if let nsError = error.map({ $0 as Error as NSError }),
           nsError.domain == NSOSStatusErrorDomain {
            switch OSStatus(truncatingIfNeeded: nsError.code) {
            case errSecNotTrusted, errSecCreateChainFailed, errSSLXCertChainInvalid:
                // Untrusted or incomplete chain — the self-signed case.
                if allowSelfSigned(host) {
                    logger.warning("Accepting untrusted-root certificate for \(host, privacy: .public) (self-signed allowance)")
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }
            case errSecCertificateExpired:
                if allowExpired(host) {
                    logger.warning("Accepting expired certificate for \(host, privacy: .public) (expired allowance)")
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }
            default:
                break
            }
        }

        logger.error("Rejecting certificate for \(host, privacy: .public): \(error.map { String(describing: $0) } ?? "trust evaluation failed", privacy: .public)")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// True when the presented leaf certificate matches the fingerprint
    /// pinned for this host. The first successful challenge after a host is
    /// trusted records the pin.
    private func leafMatchesPin(_ trust: SecTrust, host: String) -> Bool {
        guard let fingerprint = Self.leafCertificateFingerprint(of: trust) else {
            logger.error("Rejecting \(host, privacy: .public): could not read leaf certificate")
            return false
        }
        if let pinned = pinnedFingerprint(host) {
            if pinned == fingerprint {
                return true
            }
            logger.error("Rejecting \(host, privacy: .public): certificate changed since the host was trusted (fingerprint mismatch)")
            return false
        }
        storePinnedFingerprint(host, fingerprint)
        return true
    }

    /// SHA-256 of the leaf certificate's DER encoding, as lowercase hex.
    static func leafCertificateFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Jellyfin Client

actor JellyfinClient {
    private var serverURL: URL?
    private var accessToken: String?
    private var userId: String?

    private let deviceId: String
    #if os(tvOS)
    private let deviceName = "Sashimi tvOS"
    #else
    private let deviceName = "Sashimi iOS"
    #endif
    private let clientName = "Sashimi"
    private let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    // Internal so SubtitleManager can use the same certificate trust config
    let urlSession: URLSession
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

        // Create certificate validation delegate. Closures read UserDefaults
        // directly (thread-safe) because challenges arrive on the session's
        // delegate queue, not the main actor.
        self.certificateDelegate = CertificateValidationDelegate(
            allowSelfSigned: { host in
                CertificateValidationDelegate.hostAllowance(
                    host: host,
                    listKey: CertificateTrustKeys.selfSignedHosts,
                    legacyKey: CertificateTrustKeys.legacySelfSigned
                )
            },
            allowExpired: { host in
                CertificateValidationDelegate.hostAllowance(
                    host: host,
                    listKey: CertificateTrustKeys.expiredHosts,
                    legacyKey: CertificateTrustKeys.legacyExpired
                )
            },
            isHostTrusted: { host in
                ((UserDefaults.standard.array(forKey: CertificateTrustKeys.trustedHosts) as? [String]) ?? []).contains(host)
            },
            pinnedFingerprint: { host in
                (UserDefaults.standard.dictionary(forKey: CertificateTrustKeys.fingerprints) as? [String: String])?[host]
            },
            storePinnedFingerprint: { host, fingerprint in
                var pins = (UserDefaults.standard.dictionary(forKey: CertificateTrustKeys.fingerprints) as? [String: String]) ?? [:]
                pins[host] = fingerprint
                UserDefaults.standard.set(pins, forKey: CertificateTrustKeys.fingerprints)
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

    func clearCredentials() {
        self.serverURL = nil
        self.accessToken = nil
        self.userId = nil
    }

    func configure(serverURL: URL, accessToken: String? = nil, userId: String? = nil) {
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.userId = userId
        // A new server means a new link — force a fresh measurement.
        measuredBitrate = nil
    }

    /// Measured downstream bandwidth (bits/sec) from the last BitrateTest.
    private var measuredBitrate: Int?

    /// The bitrate to request on "Auto": the measured bandwidth with headroom,
    /// clamped to a sane range. Falls back to a conservative default until a
    /// measurement lands (measureBandwidth runs on connect).
    private func autoBitrateCap() -> Int {
        guard let measured = measuredBitrate else { return 20_000_000 }
        let withHeadroom = Int(Double(measured) * 0.85)
        return min(max(withHeadroom, 3_000_000), 100_000_000)
    }

    /// Time a fixed-size download from the server's BitrateTest endpoint to
    /// estimate the connection bandwidth, then cache it for Auto bitrate.
    /// Best-effort: on any failure the previous/​default cap stands.
    func measureBandwidth() async {
        guard let serverURL else { return }
        let sizeBytes = 8_000_000
        guard var components = URLComponents(
            url: serverURL.appendingPathComponent("Playback/BitrateTest"),
            resolvingAgainstBaseURL: false
        ) else { return }
        components.queryItems = [URLQueryItem(name: "Size", value: String(sizeBytes))]
        guard let url = components.url else { return }

        var req = URLRequest(url: url)
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let start = Date()
        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.01, !data.isEmpty else { return }

        let bitsPerSecond = Int((Double(data.count) * 8.0) / elapsed)
        measuredBitrate = bitsPerSecond
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
        isAuthRequest: Bool = false,
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

        // Only idempotent requests are safe to retry: a timed-out-but-delivered
        // POST (e.g. reportPlaybackStopped) would otherwise be applied twice.
        // GET and DELETE are idempotent per HTTP semantics (repeating a
        // DELETE, e.g. unmark-favorite, converges to the same state).
        let isIdempotent = method == "GET" || method == "DELETE"

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw JellyfinError.invalidResponse
            }

            // Handle 401/403 as session expiry (don't retry).
            // Exception: /Users/AuthenticateByName returns 401 for wrong
            // credentials — that's a login failure, not an expired session,
            // so don't log out or report "session expired".
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                if isAuthRequest {
                    throw JellyfinError.invalidCredentials
                }
                await SessionManager.shared.logout(reason: .sessionExpired)
                throw JellyfinError.sessionExpired
            }

            // Retry on 5xx server errors
            if (500...599).contains(httpResponse.statusCode) && isIdempotent && retryCount < maxRetries {
                let delay = pow(2.0, Double(retryCount))
                try await Task.sleep(for: .seconds(delay))
                return try await self.request(path: path, method: method, queryItems: queryItems, body: body, isAuthRequest: isAuthRequest, retryCount: retryCount + 1)
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
            if isIdempotent && retryCount < maxRetries {
                let delay = pow(2.0, Double(retryCount))
                try await Task.sleep(for: .seconds(delay))
                return try await self.request(path: path, method: method, queryItems: queryItems, body: body, isAuthRequest: isAuthRequest, retryCount: retryCount + 1)
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
            body: bodyData,
            isAuthRequest: true
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
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,ParentBackdropImageTags,UserData,Path,MediaStreams"),
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
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,UserData,ParentBackdropImageTags,Path,MediaStreams"),
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
                    // Fetch series directly sorted by when content was last added
                    itemTypes = isYouTubeLibrary ? "Episode" : "Series"
                case "movies":
                    itemTypes = "Movie"
                default:
                    itemTypes = "Movie,Series,Episode"
                }
            } else {
                itemTypes = "Movie,Series,Episode"
            }

            // Use /Items endpoint with date sorting to include watched items
            // For TV series, sort by DateLastContentAdded to show series with newest episodes first
            let isTVSeries = collectionType?.lowercased() == "tvshows" && !isYouTubeLibrary
            let sortBy = isTVSeries ? "DateLastContentAdded,SortName" : "DateCreated,SortName"

            var queryItems = [
                URLQueryItem(name: "Limit", value: "\(limit)"),
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,MediaStreams"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
                URLQueryItem(name: "SortBy", value: sortBy),
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
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,MediaStreams"),
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
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,MediaStreams"),
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

    /// Fetches one random item for the Shuffle button. `parentId` is the
    /// library or series id; `itemTypes` scopes to movies or episodes.
    func getRandomItem(parentId: String, itemTypes: [ItemType]) async throws -> BaseItemDto? {
        let response = try await getItems(
            parentId: parentId,
            includeTypes: itemTypes,
            sortBy: "Random",
            limit: 1
        )
        return response.items.first
    }

    func getPlaybackInfo(
        itemId: String,
        maxBitrate: Int? = nil,
        forceDirectPlay: Bool = false,
        forceTranscode: Bool = false
    ) async throws -> PlaybackInfoResponse {
        guard let userId else { throw JellyfinError.notConfigured }

        // Auto (no explicit cap) uses the measured connection bandwidth so we
        // don't request more than the link can carry (the cause of remote
        // stalls); explicit picks are honored as-is.
        let streamingBitrate = maxBitrate ?? autoBitrateCap()

        // An explicit quality pick (forceTranscode) beats the global Force
        // Direct Play setting for this request — otherwise the pick could
        // never take effect.
        let effectiveForceDirectPlay = forceDirectPlay && !forceTranscode

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
                    // tvOS plays HEVC and EAC3 in HLS natively — declaring
                    // them lets mkv remuxes stream-copy both tracks instead
                    // of re-encoding video / downmixing EAC3 5.1 to AAC.
                    "VideoCodec": "h264,hevc",
                    "AudioCodec": "aac,ac3,eac3",
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

        // Jellyfin's PlaybackInfo API has no "force direct play" flag.
        // Disabling DirectStream and Transcoding leaves direct play as the
        // only option, so the server either returns the original file or
        // reports the item unplayable (rather than silently remuxing).
        //
        // Conversely, forceTranscode disables DirectPlay and DirectStream so
        // the server MUST return a transcodingUrl that honors the bitrate
        // cap — the quality tiers are caps, not targets, so a direct-played
        // source under the cap would otherwise make the pick a no-op.
        //
        // MaxStreamingBitrate is sent both top-level and inside the device
        // profile: which one the server honors is version-dependent.
        let body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": streamingBitrate,
            "DeviceProfile": deviceProfile,
            "EnableDirectPlay": !forceTranscode,
            "EnableDirectStream": !effectiveForceDirectPlay && !forceTranscode,
            "EnableTranscoding": !effectiveForceDirectPlay,
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
            // api_key stays in the URL here on purpose: this URL is handed to
            // AVPlayer, which fetches the stream (and HLS sub-requests) itself
            // and has no supported way to attach auth headers. Everywhere we
            // control the fetch (URLSession), the token goes in X-Emby-Token.
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId)
        ]

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

    /// Fetches this device's own session from the server — the authoritative
    /// view of how playback is actually being delivered (DirectPlay vs a
    /// remux with video copied vs a full transcode, and why).
    struct PublicSystemInfo: Codable {
        let serverName: String?
        enum CodingKeys: String, CodingKey { case serverName = "ServerName" }
    }

    /// Unauthenticated server info — used to label saved servers.
    func getPublicSystemInfo() async throws -> PublicSystemInfo {
        let data = try await request(path: "/System/Info/Public")
        return try JSONDecoder().decode(PublicSystemInfo.self, from: data)
    }

    func getOwnSession() async throws -> SessionInfoDto? {
        let data = try await request(
            path: "/Sessions",
            queryItems: [URLQueryItem(name: "DeviceId", value: deviceId)]
        )
        let sessions = try JSONDecoder().decode([SessionInfoDto].self, from: data)
        return sessions.first(where: { $0.nowPlayingItemId?.id != nil }) ?? sessions.first
    }

    func reportPlaybackStart(itemId: String, positionTicks: Int64 = 0, playSessionId: String? = nil, playMethod: String = "DirectStream") async throws {
        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": false,
            "PlayMethod": playMethod
        ]
        if let playSessionId {
            body["PlaySessionId"] = playSessionId
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        _ = try await request(
            path: "/Sessions/Playing",
            method: "POST",
            body: bodyData
        )
    }

    func reportPlaybackProgress(itemId: String, positionTicks: Int64, isPaused: Bool, playSessionId: String? = nil) async throws {
        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused
        ]
        if let playSessionId {
            body["PlaySessionId"] = playSessionId
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        _ = try await request(
            path: "/Sessions/Playing/Progress",
            method: "POST",
            body: bodyData
        )
    }

    func reportPlaybackStopped(itemId: String, positionTicks: Int64, playSessionId: String? = nil) async throws {
        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks
        ]
        if let playSessionId {
            body["PlaySessionId"] = playSessionId
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        _ = try await request(
            path: "/Sessions/Playing/Stopped",
            method: "POST",
            body: bodyData
        )
    }

    /// Tells the server to kill the ffmpeg transcode belonging to a play
    /// session. Without this, changing quality (or leaving the player) left
    /// the old transcode running server-side.
    func stopActiveEncoding(playSessionId: String) async throws {
        _ = try await request(
            path: "/Videos/ActiveEncodings",
            method: "DELETE",
            queryItems: [
                URLQueryItem(name: "deviceId", value: deviceId),
                URLQueryItem(name: "playSessionId", value: playSessionId)
            ]
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
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,ImageTags,PremiereDate,MediaStreams"),
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
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,ParentBackdropImageTags,BackdropImageTags,UserData,ParentId,Path,MediaStreams"),
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
    case invalidCredentials
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
        case .invalidCredentials:
            return "Incorrect username or password."
        case .sessionExpired:
            return "Session expired. Please sign in again."
        case .networkError:
            return "No internet connection. Check your network."
        }
    }
}
