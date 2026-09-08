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

    // These are a MIRROR of what is on disk, not the source of truth.
    //
    // CertificateValidationDelegate.hostAllowance also writes these keys, from
    // the URLSession delegate queue, when it migrates a legacy global flag onto
    // a host. This object loads its Sets once in init(), so a didSet that wrote
    // `Array(set)` back would overwrite whatever the delegate had added in the
    // meantime -- silently revoking the current server's allowance the next
    // time the user touched any toggle, after which connections just start
    // failing. Mutations therefore go through setAllowance/setTrusted, which
    // read-modify-write the defaults and then re-read the mirror.
    @Published private(set) var selfSignedAllowedHosts: Set<String>
    @Published private(set) var expiredAllowedHosts: Set<String>
    /// Manually trusted hosts. These are pinned to the SHA-256 fingerprint of
    /// the leaf certificate they present on first acceptance.
    @Published private(set) var trustedHosts: Set<String>

    /// Read-modify-write a host list, so a concurrent write from the TLS
    /// delegate queue cannot be clobbered by a stale in-memory copy.
    private func mutateHostList(key: String, host: String, insert: Bool) {
        let defaults = UserDefaults.standard
        var hosts = Set((defaults.array(forKey: key) as? [String]) ?? [])
        if insert { hosts.insert(host) } else { hosts.remove(host) }
        defaults.set(Array(hosts), forKey: key)
        reloadFromDefaults()
    }

    /// Re-reads all three lists from disk. Public so the Settings UI can call
    /// it after a connection attempt, which is when the delegate may have
    /// migrated a legacy flag underneath us.
    func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        selfSignedAllowedHosts = Set((defaults.array(forKey: CertificateTrustKeys.selfSignedHosts) as? [String]) ?? [])
        expiredAllowedHosts = Set((defaults.array(forKey: CertificateTrustKeys.expiredHosts) as? [String]) ?? [])
        trustedHosts = Set((defaults.array(forKey: CertificateTrustKeys.trustedHosts) as? [String]) ?? [])
    }

    func setSelfSignedAllowed(_ allowed: Bool, host: String) {
        mutateHostList(key: CertificateTrustKeys.selfSignedHosts, host: host, insert: allowed)
    }

    func setExpiredAllowed(_ allowed: Bool, host: String) {
        mutateHostList(key: CertificateTrustKeys.expiredHosts, host: host, insert: allowed)
    }

    func setTrusted(_ trusted: Bool, host: String) {
        mutateHostList(key: CertificateTrustKeys.trustedHosts, host: host, insert: trusted)
        if !trusted {
            // Drop the pin too, so re-trusting the host pins whatever it
            // presents next rather than matching a stale fingerprint forever.
            var pins = (UserDefaults.standard.dictionary(forKey: CertificateTrustKeys.fingerprints) as? [String: String]) ?? [:]
            pins.removeValue(forKey: host)
            UserDefaults.standard.set(pins, forKey: CertificateTrustKeys.fingerprints)
        }
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
            setSelfSignedAllowed(newValue, host: host)
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
            setExpiredAllowed(newValue, host: host)
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

        // Must go through mutateHostList: the Sets are a mirror now, so a bare
        // insert would update memory, never reach disk, and then the legacy
        // flags below get cleared -- losing the allowance on the next launch.
        if legacySelfSigned {
            mutateHostList(key: CertificateTrustKeys.selfSignedHosts, host: host, insert: true)
        }
        if legacyExpired {
            mutateHostList(key: CertificateTrustKeys.expiredHosts, host: host, insert: true)
        }
        defaults.removeObject(forKey: CertificateTrustKeys.legacySelfSigned)
        defaults.removeObject(forKey: CertificateTrustKeys.legacyExpired)
    }

    func trustHost(_ host: String) {
        setTrusted(true, host: host)
    }

    func untrustHost(_ host: String) {
        setTrusted(false, host: host)
    }

    func isHostTrusted(_ host: String) -> Bool {
        trustedHosts.contains(host)
    }
}

// MARK: - URLSession Delegate for Certificate Validation

final class CertificateValidationDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
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

    /// Task-level variant. Nuke's `DataLoader` forwards auth challenges through
    /// `URLSessionTaskDelegate`, not the session-level method, so without this
    /// the image pipeline would fall back to default handling — and every image
    /// on a self-signed server would fail while the API worked fine.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
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

// MARK: - Bandwidth Probe

/// Measures *sustained* download throughput by streaming the server's
/// BitrateTest response and timing only the steady-state window — discarding a
/// warm-up so TCP slow-start and Wi-Fi burst buffering don't inflate the
/// reading.
///
/// The old probe timed a single 8 MB `data(for:)`. On strong Wi-Fi that whole
/// download finished *inside* the ramp, so it reported the burst peak
/// (~77 Mbps), not what the link could hold — and Auto then tried to stream a
/// 66 Mbps 4K source the link stalled on. Streaming a larger sample and
/// ignoring the first `warmup` seconds reports the rate the link actually
/// sustains, which is what the copy-vs-transcode decision needs.
///
/// Stops at whichever of `maxBytes` / `maxDuration` comes first, so fast links
/// get a big enough sample and slow links never hit the request timeout. A
/// gigabit link that finishes before the warmup window returns nil (never
/// reaches steady-state measurement) and Auto falls back to its default cap —
/// correct, because such a link is genuinely fast.
final class SustainedBandwidthProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let authDelegate: CertificateValidationDelegate
    private let warmup: TimeInterval
    private let maxDuration: TimeInterval
    private let maxBytes: Int

    private let lock = NSLock()
    private var start: Date?
    private var warmupEnd: Date?
    private var warmupEndBytes = 0
    private var received = 0
    private var finished = false
    private var continuation: CheckedContinuation<Int?, Never>?

    init(authDelegate: CertificateValidationDelegate,
         warmup: TimeInterval = 1.0,
         maxDuration: TimeInterval = 5.0,
         maxBytes: Int = 50_000_000) {
        self.authDelegate = authDelegate
        self.warmup = warmup
        self.maxDuration = maxDuration
        self.maxBytes = maxBytes
    }

    /// bits/sec from the steady-state sample, or nil if the sample is too small
    /// or too brief to trust.
    static func bitsPerSecond(measuredBytes: Int, seconds: TimeInterval) -> Int? {
        guard measuredBytes > 0, seconds >= 0.5 else { return nil }
        return Int((Double(measuredBytes) * 8.0) / seconds)
    }

    func run(request: URLRequest) async -> Int? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = maxDuration + 10
        config.timeoutIntervalForResource = maxDuration + 15
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            session.dataTask(with: request).resume()
        }
        session.invalidateAndCancel()
        return result
    }

    private func complete(with result: Int?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: result)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let now = Date()
        if start == nil { start = now }
        received += data.count
        let elapsed = now.timeIntervalSince(start ?? now)
        if warmupEnd == nil, elapsed >= warmup {
            warmupEnd = now
            warmupEndBytes = received
        }
        let done = elapsed >= maxDuration || received >= maxBytes
        lock.unlock()
        if done { dataTask.cancel() }  // -> didCompleteWithError
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let bytes = (warmupEnd != nil) ? received - warmupEndBytes : 0
        let seconds = warmupEnd.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()
        complete(with: Self.bitsPerSecond(measuredBytes: bytes, seconds: seconds))
    }

    // MARK: Auth — reuse the client's cert-trust policy so self-signed servers work

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        authDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
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
    /// Shared with the image pipeline so both use one trust policy. When they
    /// disagreed, the API worked on a self-signed server while every image
    /// silently failed.
    let certificateDelegate: CertificateValidationDelegate
    private let maxRetries = 3
    private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "JellyfinClient")

    static let shared = JellyfinClient()

    private static func deviceIdentifier() -> String {
        if let stored = UserDefaults.standard.string(forKey: "deviceId") {
            return stored
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "deviceId")
        return newId
    }

    private static func makeCertificateDelegate() -> CertificateValidationDelegate {
        // Closures read UserDefaults directly (thread-safe) because challenges
        // arrive on the session's delegate queue, not the main actor.
        CertificateValidationDelegate(
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
    }

    private static func makeURLSession(
        delegate: CertificateValidationDelegate
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = true
        config.urlCache = nil  // Disable caching to ensure fresh API responses
        return URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    private init(scopedServerURL: URL?, accessToken: String?, userId: String?) {
        self.deviceId = Self.deviceIdentifier()
        self.serverURL = scopedServerURL
        self.accessToken = accessToken
        self.userId = userId
        let delegate = Self.makeCertificateDelegate()
        self.certificateDelegate = delegate
        self.urlSession = Self.makeURLSession(delegate: delegate)
    }

    init() {
        self.init(scopedServerURL: nil, accessToken: nil, userId: nil)
    }

    /// Creates an immutable-in-practice client for one saved server. Unlike
    /// `shared.configure`, this instance can never be repointed by another
    /// route while a playback session is awaiting a report.
    init(serverURL: URL, accessToken: String, userId: String) {
        self.init(scopedServerURL: serverURL, accessToken: accessToken, userId: userId)
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
        // A new server means a new link — force a fresh measurement, and drop
        // any probe still in flight so it can't write the old server's result.
        bandwidthProbeTask?.cancel()
        bandwidthProbeTask = nil
        measuredBitrate = nil
        bandwidthMeasuredAt = nil
    }

    /// Measured downstream bandwidth (bits/sec) from the last BitrateTest.
    private var measuredBitrate: Int?

    /// When the current measurement landed. Drives staleness re-probing: the
    /// link can change under a long-lived session (roaming across mesh nodes,
    /// congestion), so a measurement older than `bandwidthMaxAge` triggers a
    /// background re-probe at the next Auto playback (jellyfin-web caches its
    /// bitrate test for the same 1 hour). The stale value still serves the
    /// current request — a re-probe never blocks playback.
    private var bandwidthMeasuredAt: Date?
    private static let bandwidthMaxAge: TimeInterval = 3600

    /// Kicks a background re-probe when the measurement is stale. Called on
    /// the Auto path at playback time; deliberately non-blocking.
    private func refreshBandwidthIfStale() {
        guard let bandwidthMeasuredAt,
              Date().timeIntervalSince(bandwidthMeasuredAt) > Self.bandwidthMaxAge else { return }
        logger.info("Bandwidth measurement stale (>1h); re-probing in background")
        startBandwidthMeasurement()
    }

    /// Retry schedule for the bandwidth probe: one immediate attempt, then
    /// these delays. A single failure (a router reboot, a Wi-Fi handoff, a
    /// server still starting up) must not leave Auto guessing all session.
    private static let bandwidthProbeBackoff: [Duration] = [.seconds(3), .seconds(15), .seconds(60)]

    /// The retrying probe, so a reconnect replaces it rather than racing it.
    private var bandwidthProbeTask: Task<Void, Never>?

    /// Where the Auto bitrate cap currently comes from. Read by Settings and
    /// logged with every PlaybackInfo request: a cap in force used to be
    /// invisible, so an unexplained transcode sent debugging to the server.
    struct BandwidthStatus: Equatable, Sendable {
        /// nil until a probe succeeds — the cap is a default until then.
        let measuredBitrate: Int?
        let cap: Int
        let isLocalServer: Bool
        /// Whether the active link is wired Ethernet. Wireless links get a
        /// smooth-4K ceiling so a heavy source is never copied over Wi-Fi.
        let isWired: Bool

        var isMeasured: Bool { measuredBitrate != nil }
    }

    var bandwidthStatus: BandwidthStatus {
        BandwidthStatus(
            measuredBitrate: measuredBitrate,
            cap: autoBitrateCap(),
            isLocalServer: PlaybackSelection.isLocalServer(serverURL),
            isWired: NetworkConnectionMonitor.shared.isWired
        )
    }

    /// The bitrate to request on "Auto": the measured bandwidth with headroom,
    /// clamped to a sane range. Until a measurement lands the default is keyed
    /// on where the server is, because a failed probe says nothing about the
    /// link (see PlaybackSelection.autoBitrateCap).
    private func autoBitrateCap() -> Int {
        PlaybackSelection.autoBitrateCap(
            measuredBitrate: measuredBitrate,
            isLocalServer: PlaybackSelection.isLocalServer(serverURL)
        )
    }

    /// Starts measuring the connection, retrying with backoff until a probe
    /// succeeds. Returns immediately; the Auto cap updates when one lands.
    /// Any probe already running is cancelled first.
    func startBandwidthMeasurement() {
        // Begin (idempotent) interface monitoring alongside the bandwidth probe
        // so the copy-vs-transcode decision knows wired from wireless.
        NetworkConnectionMonitor.shared.start()
        bandwidthProbeTask?.cancel()
        bandwidthProbeTask = Task { await self.runBandwidthProbes() }
    }

    private func runBandwidthProbes() async {
        if await measureBandwidth() { return }
        for delay in Self.bandwidthProbeBackoff {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            if await measureBandwidth() { return }
        }
        logger.warning("Bandwidth probe failed after all retries; Auto uses the default cap")
    }

    /// Time a fixed-size download from the server's BitrateTest endpoint to
    /// estimate the connection bandwidth, then cache it for Auto bitrate.
    /// Best-effort: returns false on any failure, leaving the previous/default
    /// cap standing for the caller to retry against.
    private func measureBandwidth() async -> Bool {
        guard let serverURL else { return false }
        // Request far more than we'll read: the probe streams the response and
        // stops at whichever of its byte/duration caps comes first, so this is
        // only an upper bound that fast links hit and slow links never reach.
        guard var components = URLComponents(
            url: serverURL.appendingPathComponent("Playback/BitrateTest"),
            resolvingAgainstBaseURL: false
        ) else { return false }
        components.queryItems = [URLQueryItem(name: "Size", value: "50000000")]
        guard let url = components.url else { return false }

        var req = URLRequest(url: url)
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let probe = SustainedBandwidthProbe(authDelegate: certificateDelegate)
        guard let bitsPerSecond = await probe.run(request: req), bitsPerSecond > 0 else { return false }
        measuredBitrate = bitsPerSecond
        bandwidthMeasuredAt = Date()
        logger.info("Bandwidth probe (sustained) measured \(bitsPerSecond) bps")
        return true
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

            // A failed authentication can be reported as either 401 or 403.
            // For normal requests, only 401 proves that the token is no
            // longer valid. A 403 is a permission response and must not delete
            // a healthy saved session from a read-only Jellyfin account.
            if isAuthRequest && (httpResponse.statusCode == 401 || httpResponse.statusCode == 403) {
                throw JellyfinError.invalidCredentials
            }
            if httpResponse.statusCode == 401 {
                // Only treat as session expiry when the request was against the
                // ACTIVE server. During an Add Server probe the shared client is
                // briefly pointed at a different server; a 401 there must not
                // nuke the live session (that stranded users with a saved-but-
                // tokenless server they couldn't re-add).
                let activeURL = await SessionManager.shared.serverURL
                if let activeURL, self.serverURL == activeURL {
                    await SessionManager.shared.logout(reason: .sessionExpired)
                }
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

    /// Next-up episodes. Pass `seriesId` to ask the server for the next
    /// episode of one specific series (used to resolve a Series handed to a
    /// play action into the episode that should actually play).
    func getNextUp(seriesId: String? = nil, limit: Int = 50) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        var queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,UserData,ParentBackdropImageTags,Path,MediaStreams"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            URLQueryItem(name: "EnableRewatching", value: "false"),
            URLQueryItem(name: "DisableFirstEpisode", value: "false")
        ]
        if let seriesId {
            queryItems.append(URLQueryItem(name: "SeriesId", value: seriesId))
        }

        let data = try await request(
            path: "/Shows/NextUp",
            queryItems: queryItems
        )

        let response = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return response.items
    }

    func getLatestMedia(parentId: String? = nil, limit: Int = 16, includeWatched: Bool = false, collectionType: String? = nil, groupItems: Bool = true) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }

        if includeWatched {
            // Determine item types based on collection type
            let itemTypes: String
            if let collectionType = collectionType?.lowercased() {
                switch collectionType {
                case "tvshows":
                    // Series (YouTube channels are series too) sorted by when
                    // content was last added. YouTube used to fetch Episodes and
                    // let the caller dedupe them down to channels — but a channel
                    // that uploads a burst then fills the whole limit, and the row
                    // collapses to one or two avatars until the next channel posts.
                    itemTypes = "Series"
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
            let isTVSeries = collectionType?.lowercased() == "tvshows"
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

            // Grouping is ON by default (the Recently Added row wants it: a
            // channel's burst of new videos should be one card, not five). The
            // hero passes false — grouped, a channel that posted several videos
            // collapses into its Series and the hero shows the CHANNEL rather
            // than a video. Verified against the server: grouped returns a
            // Series/Episode mix, ungrouped returns 10/10 Episodes.
            if !groupItems {
                queryItems.append(URLQueryItem(name: "GroupItems", value: "false"))
            }

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
        isResumable: Bool? = nil,
        personId: String? = nil
    ) async throws -> ItemsResponse {
        guard let userId else { throw JellyfinError.notConfigured }

        let fields = personId == nil
            ? "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,MediaStreams"
            : "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,ProductionYear,PremiereDate,UserData,ImageTags,Path,LibraryName,MediaStreams"
        var queryItems = [
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: fields),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)")
        ]

        if let parentId {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }

        if let personId {
            queryItems.append(URLQueryItem(name: "PersonIds", value: personId))
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

    /// Returns every Movie and Series visible to the current user that credits
    /// the person. Jellyfin paginates `/Items`, so keep following pages rather
    /// than silently limiting a person's filmography to the first 100 items.
    func getPersonMedia(personId: String, pageSize: Int = 100) async throws -> [BaseItemDto] {
        let pageSize = max(1, pageSize)
        var startIndex = 0
        var media: [BaseItemDto] = []

        while true {
            try Task.checkCancellation()
            let page = try await getItems(
                includeTypes: [.movie, .series],
                sortBy: "SortName",
                sortOrder: "Ascending",
                limit: pageSize,
                startIndex: startIndex,
                personId: personId
            )
            try Task.checkCancellation()

            guard !page.items.isEmpty else { break }
            media.append(contentsOf: page.items)
            startIndex += page.items.count

            if startIndex >= page.totalRecordCount || page.items.count < pageSize {
                break
            }
        }

        return media
    }

    /// Resolves a person on this server by display name. Person IDs are
    /// server-scoped, so a person ID received from another Jellyfin server
    /// cannot safely be reused when building a multi-server filmography.
    func searchPeople(named name: String, limit: Int = 20) async throws -> [PersonInfo] {
        guard let userId else { throw JellyfinError.notConfigured }

        let data = try await request(path: "/Persons", queryItems: [
            URLQueryItem(name: "SearchTerm", value: name),
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "\(max(1, limit))"),
            URLQueryItem(name: "EnableImages", value: "true")
        ])

        return try JSONDecoder().decode(PeopleResponse.self, from: data).items
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

    /// The device profile sent with every PlaybackInfo request: what the
    /// *engine this playback will use* can play natively, and the ceilings
    /// the server must respect. Internal (not private) so the profile shape
    /// is unit-testable — the `.vlc` shape depends on a key being absent,
    /// which is invisible in any log line.
    func videoDeviceProfile(engine: PlaybackEngineKind, streamingBitrate: Int, maxWidth: Int?) -> [String: Any] {
        switch engine {
        case .avFoundation:
            return avFoundationDeviceProfile(streamingBitrate: streamingBitrate, maxWidth: maxWidth)
        case .vlc:
            return vlcDeviceProfile(streamingBitrate: streamingBitrate, maxWidth: maxWidth)
        }
    }

    /// A width condition is what actually downscales. MaxStreamingBitrate is
    /// only a ceiling, so a 1080p source already under the cap was passed
    /// straight through and "720p" changed nothing.
    private func widthCodecProfiles(maxWidth: Int?) -> [[String: Any]] {
        maxWidth.map { width in
            [[
                "Type": "Video",
                "Conditions": [[
                    "Condition": "LessThanEqual",
                    "Property": "Width",
                    "Value": "\(width)",
                    "IsRequired": true
                ]]
            ]]
        } ?? []
    }

    private func avFoundationDeviceProfile(streamingBitrate: Int, maxWidth: Int?) -> [String: Any] {
        [
            "MaxStreamingBitrate": streamingBitrate,
            "MaxStaticBitrate": 100000000,
            "MusicStreamingTranscodingBitrate": 384000,
            "DirectPlayProfiles": [
                ["Container": "mp4,m4v", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"],
                ["Container": "mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3"]
            ],
            "TranscodingProfiles": [
                [
                    // fMP4 segments, NOT "ts": AVPlayer does not decode HEVC
                    // inside MPEG-TS segments (Apple's HLS spec requires fMP4
                    // for HEVC), so an mkv HEVC remux in TS played audio over
                    // a black screen (The Crown 4K DV8.1 WEBDL). With "mp4"
                    // the server emits fMP4 segments tagged hvc1 (+PQ range,
                    // DV supplemental codec) that AVPlayer actually renders.
                    "Container": "mp4",
                    "Type": "Video",
                    // HEVC is listed FIRST for the cases that DO transcode the
                    // video (an unsupported source codec, a bitrate cap, or a
                    // remote quality tier). The Apple TV cannot decode 4K H.264
                    // (it caps H.264 at 1080p; 4K needs HEVC), so an h264-first
                    // list would make the server emit undecodable 4K H.264. HEVC
                    // first keeps a 4K transcode decodable (needs the server's
                    // AllowHevcEncoding ON). Most 4K HEVC now stream-copies
                    // (AllowVideoStreamCopy=true) and never reaches this list.
                    "VideoCodec": "hevc,h264",
                    "AudioCodec": "aac,ac3,eac3",
                    "Protocol": "hls",
                    "Context": "Streaming",
                    "MaxAudioChannels": "6",
                    "MinSegments": "2",
                ]
            ],
            "ContainerProfiles": [],
            "CodecProfiles": widthCodecProfiles(maxWidth: maxWidth),
            "SubtitleProfiles": [
                ["Format": "vtt", "Method": "External"],
                ["Format": "srt", "Method": "External"]
            ]
        ]
    }

    private func vlcDeviceProfile(streamingBitrate: Int, maxWidth: Int?) -> [String: Any] {
        // libVLC demuxes essentially every container, so the direct-play
        // entry names NO container at all. The "Container" key must be
        // ABSENT — not "", not NSNull(). Jellyfin parses a null/missing
        // container list as "no restriction" (which is what lets MKV
        // direct-play), but an empty string becomes a one-element list
        // [""], which matches nothing and would transcode everything.
        let directPlay: [String: Any] = [
            "Type": "Video",
            "VideoCodec": "h264,hevc,mpeg4,mpeg2video,mpeg1video,vp8,vp9,av1,vc1,"
                + "wmv1,wmv2,wmv3,msmpeg4v1,msmpeg4v2,msmpeg4v3,theora,"
                + "prores,mjpeg,dv,flv1,h263,ffv1,dirac",
            "AudioCodec": "aac,ac3,eac3,dts,truehd,mlp,mp1,mp2,mp3,flac,alac,opus,"
                + "vorbis,speex,wavpack,wmav1,wmav2,wmapro,wmalossless,"
                + "pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_u8,"
                + "pcm_alaw,pcm_mulaw,pcm_bluray,pcm_dvd,amr_nb,amr_wb,nellymoser"
        ]
        return [
            "MaxStreamingBitrate": streamingBitrate,
            "MaxStaticBitrate": 100000000,
            "MusicStreamingTranscodingBitrate": 384000,
            "DirectPlayProfiles": [directPlay],
            // A transcoding profile stays even though direct play now wins
            // almost always: explicit quality tiers force a transcode and
            // need a URL to come back, and remote playback can exceed the
            // link. Same fMP4-not-ts shape as the AVPlayer profile.
            "TranscodingProfiles": [
                [
                    "Container": "mp4",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc",
                    // Widened vs AVPlayer: VLC decodes all of these in HLS.
                    "AudioCodec": "aac,ac3,eac3,mp3,flac,opus",
                    "Protocol": "hls",
                    "Context": "Streaming",
                    "MaxAudioChannels": "8",
                    "MinSegments": "2",
                ]
            ],
            "ContainerProfiles": [],
            "CodecProfiles": widthCodecProfiles(maxWidth: maxWidth),
            // Embedded formats ride along inside the direct-played file and
            // VLC renders them (incl. ASS styling and image subs), which
            // removes SubtitleCodecNotSupported as a transcode reason.
            "SubtitleProfiles": [
                ["Format": "subrip", "Method": "Embed"],
                ["Format": "ass", "Method": "Embed"],
                ["Format": "ssa", "Method": "Embed"],
                ["Format": "pgssub", "Method": "Embed"],
                ["Format": "dvdsub", "Method": "Embed"],
                ["Format": "vtt", "Method": "Embed"],
                ["Format": "sub", "Method": "Embed"],
                ["Format": "mov_text", "Method": "Embed"],
                ["Format": "vtt", "Method": "External"],
                ["Format": "srt", "Method": "External"],
                ["Format": "ass", "Method": "External"],
                ["Format": "ssa", "Method": "External"]
            ]
        ]
    }

    /// Records what Auto is actually asking the server for. Without this the
    /// only symptom of a bogus cap is an unexplained transcode, which reads as
    /// "the server is struggling" and sends debugging to the wrong place.
    private func logAutoBitrateCap(width: Int?) {
        let status = bandwidthStatus
        logger.info(
            """
            Auto bitrate cap \(status.cap, privacy: .public) bps \
            (\(status.isMeasured ? "measured" : "no measurement", privacy: .public), \
            \(status.isLocalServer ? "local" : "remote", privacy: .public) server), \
            width \(width.map(String.init) ?? "unrestricted", privacy: .public)
            """
        )
    }

    func getPlaybackInfo(
        itemId: String,
        itemType: ItemType? = nil,
        engine: PlaybackEngineKind,
        maxBitrate: Int? = nil,
        maxWidth: Int? = nil,
        forceDirectPlay: Bool = false,
        forceTranscode: Bool = false,
        allowVideoStreamCopy: Bool = true
    ) async throws -> PlaybackInfoResponse {
        // Defensive guard: PlaybackInfo for a container type (Series, Season,
        // BoxSet, folder) is a guaranteed server 500 — Jellyfin throws
        // InvalidCastException casting it to IHasMediaSources. Seen in
        // production when a series id reached this call. Callers must resolve
        // to an episode/movie first; refuse here so the mistake is loud and
        // local instead of a cryptic server error mid-playback.
        if let itemType, !itemType.isPlayableMediaType {
            logger.error("Refusing PlaybackInfo POST for non-playable item type \(itemType.rawValue, privacy: .public) (item \(itemId, privacy: .public)) — resolve to an episode/movie first")
            throw JellyfinError.nonPlayableItem(itemType)
        }
        guard let userId else { throw JellyfinError.notConfigured }

        // Auto (no explicit cap) uses the measured connection bandwidth so we
        // don't request more than the link can carry (the cause of remote
        // stalls); explicit picks are honored as-is. A stale measurement kicks
        // a background re-probe but still serves this request.
        if maxBitrate == nil { refreshBandwidthIfStale() }
        let streamingBitrate = maxBitrate ?? autoBitrateCap()

        // A bitrate cap with no width condition makes the server re-encode at
        // the source resolution, so a capped 4K stream was re-encoded at full
        // 4K — the most expensive way to reach the ceiling. When the caller
        // picked no tier, derive a width the cap can actually carry.
        let effectiveMaxWidth = maxWidth ?? PlaybackSelection.autoMaxWidth(forBitrateCap: streamingBitrate)

        if maxBitrate == nil { logAutoBitrateCap(width: effectiveMaxWidth) }

        // An explicit quality pick (forceTranscode) beats the global Force
        // Direct Play setting for this request — otherwise the pick could
        // never take effect.
        let effectiveForceDirectPlay = forceDirectPlay && !forceTranscode

        let deviceProfile = videoDeviceProfile(engine: engine, streamingBitrate: streamingBitrate, maxWidth: effectiveMaxWidth)

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
            // Allow video stream-copy (the native-correct path). AVPlayer can't
            // demux MKV, so an MKV goes through HLS — but for content the Apple TV
            // decodes natively (e.g. a 4K HDR10 HEVC remux), the server should
            // stream-COPY the video untouched and only remux the container +
            // transcode incompatible audio (DTS→AAC). That preserves native 4K
            // HDR at near-zero server cost.
            //
            // History: #359 set this false to force a re-encode as a workaround
            // for the stream-copy HLS seek-freeze (jellyfin#16070/#4188 — the
            // playlist grid and the restarted ffmpeg's segment grid diverge on
            // seek). That was unworkable: forcing a real-time re-encode of an
            // 88 GB 4K HDR remux OOM-killed ffmpeg (exit 137) into a restart
            // storm, so 4K titles could not play at all (CoreMediaError -12889).
            // The seek-freeze is handled the way the official clients handle
            // broken playback: an error/stall RECOVERY fallback (see
            // PlayerViewModel.attemptPlaybackRecovery) rebuilds the session at
            // the current position forcing a transcode, escalating to
            // allowVideoStreamCopy=false on a second failure — recovery only,
            // never as the default path.
            "AllowVideoStreamCopy": allowVideoStreamCopy,
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

    /// Direct audio stream for a theme. `/Audio/{id}/universal` returns 400
    /// without a full device profile; `stream.mp3` serves the file as-is,
    /// which is what a theme is.
    func getAudioStreamURL(itemId: String) -> URL? {
        guard let serverURL, let accessToken else { return nil }
        var components = URLComponents(string: serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        components?.path += "/Audio/\(itemId)/stream.mp3"
        components?.queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            // api_key stays in the URL because AVPlayer fetches this itself and
            // has no supported way to attach auth headers - same reasoning as
            // getPlaybackURL above.
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

    nonisolated func personImageURL(
        personId: String,
        maxWidth: Int = 150,
        serverURL overrideServerURL: URL? = nil
    ) -> URL? {
        let url: URL
        if let overrideServerURL {
            url = overrideServerURL
        } else {
            guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
                  let defaultURL = URL(string: serverURL) else { return nil }
            url = defaultURL
        }

        guard var components = URLComponents(url: url.appendingPathComponent("/Items/\(personId)/Images/Primary"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)")
        ]

        return components.url
    }

    /// Synchronous image URL builder - uses cached server URL from UserDefaults
    nonisolated func syncImageURL(
        itemId: String,
        imageType: String = "Primary",
        maxWidth: Int = 400,
        serverURL overrideServerURL: URL? = nil
    ) -> URL? {
        let url: URL
        if let overrideServerURL {
            url = overrideServerURL
        } else {
            guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
                  let defaultURL = URL(string: serverURL) else { return nil }
            url = defaultURL
        }

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
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,ProductionYear,PremiereDate,ParentBackdropImageTags,BackdropImageTags,UserData,ParentId,Path,LibraryName,MediaStreams"),
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
                URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,CommunityRating,OfficialRating,Genres,Taglines,People,UserData,Chapters,ParentBackdropImageTags,RemoteTrailers,LocalTrailerCount"),
                URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
            ]
        )

        return try JSONDecoder().decode(BaseItemDto.self, from: data)
    }

    /// Local trailer items (from Trailarr etc.) that Jellyfin exposes as
    /// playable Trailer items. The endpoint returns a JSON array directly.
    func getLocalTrailers(itemId: String) async throws -> [BaseItemDto] {
        guard let userId else { throw JellyfinError.notConfigured }
        let data = try await request(path: "/Users/\(userId)/Items/\(itemId)/LocalTrailers", queryItems: [])
        return (try? JSONDecoder().decode([BaseItemDto].self, from: data)) ?? []
    }

    /// Theme songs Jellyfin has for an item. Populated by the Theme Songs
    /// server plugin, which writes `theme.mp3` into the series folder.
    /// Returns an empty array when the series has none — roughly 40% of a
    /// typical library, which is normal and not an error.
    func getThemeSongs(itemId: String) async throws -> [BaseItemDto] {
        let data = try await request(path: "/Items/\(itemId)/ThemeMedia", queryItems: [])
        let decoded = try? JSONDecoder().decode(ThemeMediaResponse.self, from: data)
        return decoded?.themeSongsResult?.items ?? []
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

private let multiServerMediaLogger = Logger(
    subsystem: "com.mondominator.sashimi",
    category: "MultiServerMedia"
)

/// Searches every saved server concurrently. Each server owns its own Jellyfin
/// client because item IDs and access tokens are server-scoped.
enum MultiServerSearchService {
    struct SearchResult: Sendable {
        let results: [ServerMediaResult]
        let failedServerCount: Int

        var hasServerFailures: Bool {
            failedServerCount > 0
        }
    }

    static func search(query: String, limit: Int = 50) async -> [ServerMediaResult] {
        await searchWithStatus(query: query, limit: limit).results
    }

    static func searchWithStatus(query: String, limit: Int = 50) async -> SearchResult {
        let servers = await MainActor.run { SessionManager.shared.servers }

        let responses = await withTaskGroup(of: ServerSearchResponse.self, returning: [ServerSearchResponse].self) { group in
            for server in servers {
                let token = await MainActor.run {
                    SessionManager.shared.token(for: server, allowLegacyFallback: true)
                }
                guard let token else {
                    multiServerMediaLogger.debug(
                        "Search skipped for server without a saved session: \(server.url.host ?? "unknown", privacy: .private(mask: .hash))"
                    )
                    continue
                }

                group.addTask {
                    let client = JellyfinClient()
                    await client.configure(serverURL: server.url, accessToken: token, userId: server.userId)

                    do {
                        let items = try await client.search(query: query, limit: limit)
                        return ServerSearchResponse(
                            results: items.map {
                                ServerMediaResult(
                                    item: $0,
                                    serverID: server.id,
                                    serverName: server.displayName,
                                    serverURL: server.url
                                )
                            },
                            succeeded: true
                        )
                    } catch is CancellationError {
                        return ServerSearchResponse(results: [], succeeded: false)
                    } catch {
                        multiServerMediaLogger.error(
                            "Search failed on \(server.url.host ?? "unknown", privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
                        )
                        return ServerSearchResponse(results: [], succeeded: false)
                    }
                }
            }

            var responses: [ServerSearchResponse] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        return SearchResult(
            results: responses.flatMap(\.results),
            failedServerCount: responses.count(where: { !$0.succeeded })
        )
    }

    private struct ServerSearchResponse: Sendable {
        let results: [ServerMediaResult]
        let succeeded: Bool
    }
}

/// Resolves a person's server-local ID and fetches their filmography on every
/// saved server. The originating server can use the ID Jellyfin already sent
/// with the open detail page; all other servers resolve the person by name.
protocol PeopleFilmographyClient: Sendable {
    func searchPeople(named name: String, limit: Int) async throws -> [PersonInfo]
    func getPersonMedia(personId: String, pageSize: Int) async throws -> [BaseItemDto]
}

extension JellyfinClient: PeopleFilmographyClient {}

enum MultiServerPeopleError: LocalizedError, Equatable {
    case noAvailableServerSessions
    case allServersFailed

    var errorDescription: String? {
        switch self {
        case .noAvailableServerSessions, .allServersFailed:
            return "No connected server could load this person's filmography."
        }
    }
}

struct MultiServerPeopleServerResult {
    let items: [ServerMediaResult]
    let succeeded: Bool
}

enum MultiServerPeopleService {
    typealias TokenProvider = @Sendable (ServerConfig) async -> String?
    typealias ClientFactory = @Sendable (ServerConfig, String) async -> any PeopleFilmographyClient

    private struct FilmographyRequest {
        let server: ServerConfig
        let token: String
        let person: PersonInfo
        let originatingServerID: String?
        let pageSize: Int
        let clientFactory: ClientFactory
    }

    // The production path and its injectable test seams intentionally stay
    // together so token/session accounting cannot diverge from aggregation.
    // swiftlint:disable:next function_body_length
    static func search(
        person: PersonInfo,
        originatingServerID: String?,
        pageSize: Int = 100,
        servers suppliedServers: [ServerConfig]? = nil,
        tokenProvider suppliedTokenProvider: TokenProvider? = nil,
        clientFactory suppliedClientFactory: ClientFactory? = nil
    ) async throws -> [ServerMediaResult] {
        try Task.checkCancellation()
        let servers: [ServerConfig]
        if let suppliedServers {
            servers = suppliedServers
        } else {
            servers = await MainActor.run { SessionManager.shared.servers }
        }
        let tokenProvider = suppliedTokenProvider ?? { server in
            await MainActor.run {
                SessionManager.shared.token(for: server, allowLegacyFallback: true)
            }
        }
        let clientFactory = suppliedClientFactory ?? { server, token in
            let client = JellyfinClient()
            await client.configure(serverURL: server.url, accessToken: token, userId: server.userId)
            return client
        }
        var attemptedServerCount = 0

        let responses = await withTaskGroup(
            of: MultiServerPeopleServerResult.self,
            returning: [MultiServerPeopleServerResult].self
        ) { group in
            for server in servers {
                let token = await tokenProvider(server)
                guard let token else {
                    multiServerMediaLogger.debug(
                        "Filmography skipped for server without a saved session: \(server.url.host ?? "unknown", privacy: .private(mask: .hash))"
                    )
                    continue
                }
                attemptedServerCount += 1

                group.addTask {
                    do {
                        return MultiServerPeopleServerResult(
                            items: try await loadFilmography(FilmographyRequest(
                                server: server,
                                token: token,
                                person: person,
                                originatingServerID: originatingServerID,
                                pageSize: pageSize,
                                clientFactory: clientFactory
                            )),
                            succeeded: true
                        )
                    } catch is CancellationError {
                        return MultiServerPeopleServerResult(items: [], succeeded: false)
                    } catch {
                        multiServerMediaLogger.error(
                            "Filmography failed on \(server.url.host ?? "unknown", privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
                        )
                        return MultiServerPeopleServerResult(items: [], succeeded: false)
                    }
                }
            }

            return await group.reduce(into: []) { results, response in
                results.append(response)
            }
        }

        try Task.checkCancellation()
        return try aggregateFilmographyResults(
            responses,
            attemptedServerCount: attemptedServerCount
        )
    }

    /// Keeps partial successes visible while making an all-server outage a
    /// real error instead of a misleading empty filmography.
    static func aggregateFilmographyResults(
        _ responses: [MultiServerPeopleServerResult],
        attemptedServerCount: Int
    ) throws -> [ServerMediaResult] {
        guard attemptedServerCount > 0 else {
            throw MultiServerPeopleError.noAvailableServerSessions
        }
        guard responses.contains(where: \.succeeded) else {
            throw MultiServerPeopleError.allServersFailed
        }
        return responses.flatMap(\.items)
    }

    private static func loadFilmography(_ request: FilmographyRequest) async throws -> [ServerMediaResult] {
        let client = await request.clientFactory(request.server, request.token)

        let serverPersonID: String?
        if request.server.id == request.originatingServerID {
            serverPersonID = request.person.id
        } else {
            let candidates = try await client.searchPeople(named: request.person.name, limit: 20)
            serverPersonID = candidates.first {
                $0.matchingNameKey == request.person.matchingNameKey
            }?.id
        }

        guard let serverPersonID else {
            multiServerMediaLogger.debug(
                "Filmography person not found on \(request.server.url.host ?? "unknown", privacy: .private(mask: .hash))"
            )
            return []
        }

        let items = try await client.getPersonMedia(
            personId: serverPersonID,
            pageSize: request.pageSize
        )
        multiServerMediaLogger.debug(
            "Filmography loaded from \(request.server.url.host ?? "unknown", privacy: .private(mask: .hash)): \(items.count, privacy: .public) titles"
        )

        return items.map {
            ServerMediaResult(
                item: $0,
                serverID: request.server.id,
                serverName: request.server.displayName,
                serverURL: request.server.url
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
    case nonPlayableItem(ItemType)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Not connected to a server. Please sign in."
        case .nonPlayableItem(let type):
            return "This \(type.rawValue.lowercased()) can't be played directly. Pick an episode to play."
        case .invalidResponse:
            return "The server returned an unexpected response. Try again."
        case .invalidURL:
            return "Could not connect to the server. Check server address."
        case .httpError(let code):
            switch code {
            case 401:
                return "Session expired. Please sign in again."
            case 403:
                return "The server denied access to this request."
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
