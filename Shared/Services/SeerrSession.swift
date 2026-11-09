import Foundation
import os

/// Where the Seerr session cookie is kept. Production uses the Keychain;
/// tests keep it in memory.
protocol SeerrCredentialStore: AnyObject {
    func cookie(forKey key: String) -> String?
    func setCookie(_ cookie: String?, forKey key: String)
}

final class KeychainSeerrCredentials: SeerrCredentialStore {
    func cookie(forKey key: String) -> String? {
        KeychainHelper.get(forKey: key)
    }

    func setCookie(_ cookie: String?, forKey key: String) {
        if let cookie {
            _ = KeychainHelper.save(cookie, forKey: key)
        } else {
            KeychainHelper.delete(forKey: key)
        }
    }
}

enum SeerrAuthState: Equatable {
    /// No account: nothing about requests appears anywhere in the app.
    case notConfigured
    /// A sign-in is being exchanged for a session.
    case signingIn
    /// The TV is showing a plex.tv/link code (or the phone has Plex's sign-in
    /// page open) and waiting for the person.
    case awaitingPlex(code: String)
    case signedIn(SeerrUser)
    /// The server stopped accepting the session: Settings asks to sign in
    /// again; the rest of the app hides requests as if not set up.
    case expired

    var user: SeerrUser? {
        if case .signedIn(let user) = self { return user }
        return nil
    }
}

/// The person's Seerr account: which server, whether they're signed in, and
/// the client the request screens use. Each person signs in as themselves
/// (Plex or a Seerr username), so approvals and quotas work exactly as on
/// the website. No admin API key is ever stored.
@MainActor
final class SeerrSession: ObservableObject {
    static let shared = SeerrSession(
        defaults: .standard,
        credentials: KeychainSeerrCredentials(),
        pollInterval: .seconds(2)
    )

    @Published private(set) var state: SeerrAuthState = .notConfigured
    /// Nil until the person enters one: there is no default server, and
    /// with none the app makes no Seerr calls and shows no request UI.
    @Published private(set) var serverURL: URL?
    /// The server's own name ("MondoVision"), for "from MondoVision".
    @Published private(set) var applicationTitle = "Seerr"
    @Published private(set) var partialRequestsEnabled = true
    @Published private(set) var localLoginEnabled = true
    @Published var errorMessage: String?
    /// Handed the Plex token once a Plex sign-in has succeeded, so the
    /// Watchlist can link the same account. Its outcome never changes this
    /// session's state or messages. The token is not kept.
    var plexTokenObserver: (@MainActor (_ token: String) async -> Void)?
    /// Bumped after a request is sent or cancelled, so open lists reload.
    @Published private(set) var requestsRevision = 0

    private(set) var client: SeerrClient?
    private let defaults: UserDefaults
    private let credentials: SeerrCredentialStore
    private let pollInterval: Duration
    private var plexWait: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "SeerrSession")

    private enum Keys {
        static let server = "seerr.serverURL"
        static let userId = "seerr.user.id"
        static let userName = "seerr.user.name"
        static let permissions = "seerr.user.permissions"
        static let title = "seerr.applicationTitle"
    }

    init(defaults: UserDefaults, credentials: SeerrCredentialStore, pollInterval: Duration) {
        self.defaults = defaults
        self.credentials = credentials
        self.pollInterval = pollInterval
        serverURL = defaults.string(forKey: Keys.server).flatMap(Self.normalizedServerURL)
        applicationTitle = defaults.string(forKey: Keys.title) ?? "Seerr"
    }

    var isActive: Bool { state.user != nil }

    /// Signing in needs a request server to sign in to.
    var canSignIn: Bool { serverURL != nil }

    /// Settings enables the sign-in buttons only for an address that would
    /// be accepted.
    static func canSignIn(serverText: String) -> Bool {
        normalizedServerURL(serverText) != nil
    }

    /// What the signed-in account may do; none while signed out.
    var permissions: SeerrPermissions { state.user?.permissionSet ?? [] }

    /// "requests.example.com" → https://requests.example.com; trailing slashes dropped. Only
    /// http and https.
    static func normalizedServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The Keychain account for one server's cookie, so a second household's
    /// server never receives this one's session.
    static func cookieKey(for url: URL) -> String {
        "seerr.session.\(url.absoluteString.lowercased())"
    }

    /// Only while signed out: a session belongs to the server that issued it.
    @discardableResult
    func setServerAddress(_ text: String) -> Bool {
        guard !isActive, let url = Self.normalizedServerURL(text) else { return false }
        if url != serverURL {
            serverURL = url
            defaults.set(url.absoluteString, forKey: Keys.server)
            if state == .expired { state = .notConfigured }
        }
        return true
    }

    // MARK: Launch

    /// At launch: a stored cookie is checked with the server. A server that
    /// can't be reached keeps the last known account (it's not a sign-out).
    func restore() async {
        // No account: stay off the network entirely.
        guard let serverURL,
              let cookie = credentials.cookie(forKey: Self.cookieKey(for: serverURL)) else { return }
        await refreshPublicSettings()
        let client = SeerrClient(baseURL: serverURL, cookie: cookie)
        do {
            let user = try await client.currentUser()
            signedIn(user, cookie: cookie, client: client)
        } catch SeerrError.unauthorized {
            expire()
        } catch {
            guard let id = defaults.object(forKey: Keys.userId) as? Int else { return }
            self.client = client
            state = .signedIn(SeerrUser(
                id: id,
                displayName: defaults.string(forKey: Keys.userName),
                permissions: defaults.object(forKey: Keys.permissions) as? Int
            ))
        }
    }

    func refreshPublicSettings() async {
        guard let serverURL,
              let settings = try? await SeerrClient(baseURL: serverURL, cookie: nil).publicSettings() else { return }
        if let title = settings.applicationTitle, !title.isEmpty {
            applicationTitle = title
            defaults.set(title, forKey: Keys.title)
        }
        partialRequestsEnabled = settings.partialRequestsEnabled ?? true
        localLoginEnabled = settings.localLogin ?? true
    }

    // MARK: Sign in

    func signInLocal(email: String, password: String) async {
        guard let serverURL else { return }
        errorMessage = nil
        let previous = state
        state = .signingIn
        let client = SeerrClient(baseURL: serverURL, cookie: nil)
        do {
            let result = try await client.signInLocal(email: email.trimmingCharacters(in: .whitespaces), password: password)
            signedIn(result.user, cookie: result.cookie, client: client)
            await refreshPublicSettings()
        } catch {
            state = previous == .expired ? .expired : .notConfigured
            errorMessage = error.localizedDescription
        }
    }

    /// Step 1 of Plex sign-in: get a PIN. The TV shows its code
    /// (`strong: false`, four characters for plex.tv/link); the phone opens
    /// Plex's sign-in page with it (`strong: true`).
    func beginPlexSignIn(strong: Bool) async -> PlexPin? {
        guard canSignIn else { return nil }
        errorMessage = nil
        do {
            let pin = try await plexClient.createPin(strong: strong)
            state = .awaitingPlex(code: pin.code)
            return pin
        } catch {
            errorMessage = "Couldn't start Plex sign-in. \(error.localizedDescription)"
            return nil
        }
    }

    /// Step 2: wait for the person to link the code, then trade the Plex
    /// token for a Seerr session. Ends on cancel, on expiry (15 minutes), or
    /// on sign-in.
    func completePlexSignIn(pin: PlexPin) async {
        let deadline = ContinuousClock.now + .seconds(15 * 60)
        let token = await plexClient.waitForToken(
            pinId: pin.id, deadline: deadline, interval: pollInterval,
            isWaiting: { self.state == .awaitingPlex(code: pin.code) }
        )
        if let token {
            await exchangePlexToken(token)
            return
        }
        if Task.isCancelled { return }
        if state == .awaitingPlex(code: pin.code) {
            state = .notConfigured
            errorMessage = "The Plex code expired. Try again."
        }
    }

    func cancelPlexSignIn() {
        plexWait?.cancel()
        if case .awaitingPlex = state { state = .notConfigured }
    }

    /// The tvOS flow in one call: show a code and wait for it.
    func startPlexCodeSignIn() {
        plexWait?.cancel()
        plexWait = Task {
            guard let pin = await beginPlexSignIn(strong: false) else { return }
            await completePlexSignIn(pin: pin)
        }
    }

    func plexWebSignInURL(for pin: PlexPin) -> URL {
        PlexPinClient.webSignInURL(clientIdentifier: plexClientIdentifier, code: pin.code)
    }

    private func exchangePlexToken(_ token: String) async {
        guard let serverURL else {
            state = .notConfigured
            return
        }
        state = .signingIn
        let client = SeerrClient(baseURL: serverURL, cookie: nil)
        do {
            let result = try await client.signInWithPlex(authToken: token)
            signedIn(result.user, cookie: result.cookie, client: client)
            await refreshPublicSettings()
            await plexTokenObserver?(token)
        } catch {
            state = .notConfigured
            errorMessage = (error as? SeerrError) == .invalidCredentials
                ? "That Plex account doesn't have access to \(applicationTitle)."
                : error.localizedDescription
        }
    }

    private var plexClient: PlexPinClient { PlexPinClient(clientIdentifier: plexClientIdentifier) }

    /// Stable per install, so plex.tv lists one "Sashimi" device, not one per
    /// sign-in (shared with Connect Plex).
    private var plexClientIdentifier: String { PlexClientIdentity.identifier(defaults: defaults) }

    // MARK: Sign out and expiry

    func signOut() async {
        plexWait?.cancel()
        await client?.logout()
        forget()
        state = .notConfigured
    }

    /// Any request screen hands its errors here. A 401/403 is checked with
    /// `/auth/me` before it counts as a sign-out: Seerr also answers 401
    /// for things like cancelling a request that's no longer pending.
    func handle(_ error: Error) async {
        guard (error as? SeerrError) == .unauthorized, let client else { return }
        do {
            _ = try await client.currentUser()
        } catch SeerrError.unauthorized {
            expire()
        } catch {
            // Unreachable: not evidence of a sign-out.
        }
    }

    func requestsChanged() {
        requestsRevision += 1
    }

    private func signedIn(_ user: SeerrUser, cookie: String, client: SeerrClient) {
        if let serverURL {
            credentials.setCookie(cookie, forKey: Self.cookieKey(for: serverURL))
        }
        defaults.set(user.id, forKey: Keys.userId)
        defaults.set(user.name, forKey: Keys.userName)
        defaults.set(user.permissions, forKey: Keys.permissions)
        self.client = client
        errorMessage = nil
        state = .signedIn(user)
        logger.info("Signed in to Seerr")
    }

    private func expire() {
        forget()
        state = .expired
        logger.info("Seerr session expired")
    }

    private func forget() {
        if let serverURL {
            credentials.setCookie(nil, forKey: Self.cookieKey(for: serverURL))
        }
        defaults.removeObject(forKey: Keys.userId)
        defaults.removeObject(forKey: Keys.userName)
        defaults.removeObject(forKey: Keys.permissions)
        client = nil
    }
}
