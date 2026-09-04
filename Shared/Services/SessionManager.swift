import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.sashimi.app", category: "SessionManager")

enum LogoutReason {
    case userInitiated
    case sessionExpired
}

enum SessionError: LocalizedError {
    /// The Keychain rejected the access token write. Login is aborted so the
    /// user sees the failure now instead of being silently signed out on the
    /// next launch (restoreSession requires the token to be in the Keychain).
    case credentialStorageFailed
    /// Same server URL + user already saved.
    case duplicateServer
    /// A connection identity change cannot be verified without a password.
    case passwordRequiredForConnectionChange
    /// The server record being edited no longer exists.
    case serverNotFound
    /// The edit form supplied an invalid server address.
    case invalidServerURL
    /// The edit form supplied an empty username.
    case invalidUsername

    var errorDescription: String? {
        switch self {
        case .credentialStorageFailed:
            return "Could not save credentials securely. Please try signing in again."
        case .duplicateServer:
            return "That server and user are already added."
        case .passwordRequiredForConnectionChange:
            return "Enter the password to verify the updated server connection."
        case .serverNotFound:
            return "That saved server is no longer available."
        case .invalidServerURL:
            return "Enter a valid http:// or https:// server address."
        case .invalidUsername:
            return "Enter a username."
        }
    }
}

/// A saved Jellyfin server + account. Tokens live in the Keychain under
/// "accessToken.<id>"; everything else persists as JSON in UserDefaults.
struct ServerConfig: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// A local-only name chosen by the user. `name` remains Jellyfin's name
    /// (or the host fallback) so clearing an alias restores the server's
    /// natural display name without another network request.
    var nameOverride: String?
    var url: URL
    var username: String
    var userId: String

    init(
        id: String,
        name: String,
        url: URL,
        username: String,
        userId: String,
        nameOverride: String? = nil
    ) {
        self.id = id
        self.name = name
        self.nameOverride = nameOverride
        self.url = url
        self.username = username
        self.userId = userId
    }

    var displayName: String {
        let trimmedOverride = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedOverride.isEmpty ? name : trimmedOverride
    }
}

/// A small async mutex used to serialize changes to JellyfinClient.shared.
/// Main-actor isolation alone is not enough here: every actor hop can suspend
/// and let another task repoint the shared client in the middle of a scope.
private actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
}

/// Handle returned by a temporary server-client scope. The handle lets a
/// detail route restore the scope it entered from, even when scopes are
/// nested or disappear out of order during a navigation transition.
struct ServerClientScopeToken: Hashable {
    fileprivate let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

struct ServerClientScopeStack {
    struct Entry: Equatable {
        let token: ServerClientScopeToken
        var previousScopeToken: ServerClientScopeToken?
        var previousServerID: String?
    }

    struct Removal {
        let entry: Entry
        let wasTop: Bool
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func begin(previousServerID: String?) -> ServerClientScopeToken {
        let scope = ServerClientScopeToken()
        entries.append(
            Entry(
                token: scope,
                previousScopeToken: entries.last?.token,
                previousServerID: previousServerID
            )
        )
        return scope
    }

    mutating func end(_ scope: ServerClientScopeToken) -> Removal? {
        guard let index = entries.firstIndex(where: { $0.token == scope }) else {
            return nil
        }

        let entry = entries.remove(at: index)
        let wasTop = index == entries.count
        if !wasTop {
            for childIndex in index..<entries.count
                where entries[childIndex].previousScopeToken == entry.token {
                entries[childIndex].previousServerID = entry.previousServerID
                entries[childIndex].previousScopeToken = entry.previousScopeToken
            }
        }

        return Removal(entry: entry, wasTop: wasTop)
    }
}

// SessionManager owns authentication, persistence, and temporary client
// scopes; keeping those transitions together is safer than splitting the
// state machine across unrelated services.
@MainActor
// Session state and its edit transaction stay together so the transaction can
// retain private access to the client configuration and credential lifecycle.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: UserDto?
    @Published private(set) var serverURL: URL?
    @Published private(set) var servers: [ServerConfig] = []
    @Published private(set) var activeServerId: String?
    @Published private(set) var defaultServerId: String?
    /// Changes only when the active server's connection identity changes, so
    /// the app can rebuild content view models without refreshing for aliases.
    @Published private(set) var serverConnectionRevision = 0
    @Published var logoutReason: LogoutReason?
    /// Set when the user picks a saved server whose token was dropped by a past
    /// session expiry — the UI presents a prefilled re-auth for it. Cleared on
    /// success or cancel.
    @Published var reauthServer: ServerConfig?

    private let serversKey = "servers"
    private let activeServerIdKey = "activeServerId"
    private let defaultServerIdKey = "defaultServerId"

    // Legacy single-server keys (pre multi-server)
    private let userDefaultsServerURLKey = "serverURL"
    private let userDefaultsUserIdKey = "userId"
    private let keychainAccessTokenKey = "accessToken"
    /// Identifies which saved server last populated the legacy global token
    /// slot. Token fallback must never mistake that token for another saved
    /// server's credential.
    private let legacyTokenServerIDKey = "legacyAccessTokenServerID"
    /// Pre-Keychain builds stored the token in plaintext under this key.
    private let legacyUserDefaultsTokenKey = "accessToken"

    private let clientConfigurationMutex = AsyncMutex()
    /// Coalesces app-start restoration with App Intent readiness. An intent
    /// can arrive before the root view's task has finished restoring the
    /// persisted server and credentials, so both entry points must await the
    /// same operation instead of inspecting partially loaded state.
    private var sessionRestoreTask: Task<Void, Never>?
    private var hasCompletedInitialRestore = false
    /// The server currently configured in JellyfinClient.shared. This is
    /// deliberately separate from activeServerId because a detail route can
    /// temporarily use another saved server without changing app chrome.
    private var configuredServerID: String?
    private var clientScopeStack = ServerClientScopeStack()

    var activeServer: ServerConfig? {
        servers.first(where: { $0.id == activeServerId })
    }

    var defaultServer: ServerConfig? {
        servers.first(where: { $0.id == defaultServerId })
    }

    var shouldShowDefaultServerBadge: Bool {
        servers.count > 1
    }

    func isDefaultServer(_ id: String) -> Bool {
        defaultServerId == id
    }

    func shouldShowSetAsDefault(for id: String) -> Bool {
        servers.count > 1 && !isDefaultServer(id)
    }

    /// The root content identity. Switching servers already changes the first
    /// component; editing an active URL or credential changes the revision.
    var activeSessionIdentity: String {
        "\(activeServerId ?? "none"):\(serverConnectionRevision)"
    }

#if DEBUG
    /// The production singleton uses the private initializer below. This
    /// debug-only initializer lets the hosted unit-test target create an
    /// isolated manager without competing with the app's singleton session.
    init(
        restoreOnLaunch: Bool = true,
        initialServers: [ServerConfig] = [],
        initialActiveServerId: String? = nil,
        initialDefaultServerId: String? = nil
    ) {
        servers = initialServers
        activeServerId = initialActiveServerId
        defaultServerId = initialDefaultServerId
        hasCompletedInitialRestore = !restoreOnLaunch && !initialServers.isEmpty
        guard restoreOnLaunch else { return }
        beginSessionRestore()
    }
#else
    private init() {
        beginSessionRestore()
    }
#endif

    // MARK: - Persistence

    private func loadServers() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let list = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = list
        }
        activeServerId = UserDefaults.standard.string(forKey: activeServerIdKey)
        defaultServerId = UserDefaults.standard.string(forKey: defaultServerIdKey)
    }

    @discardableResult
    private func saveServers() -> Bool {
        guard let data = try? JSONEncoder().encode(servers) else {
            logger.error("Could not encode saved server metadata")
            return false
        }
        UserDefaults.standard.set(data, forKey: serversKey)
        UserDefaults.standard.set(activeServerId, forKey: activeServerIdKey)
        UserDefaults.standard.set(defaultServerId, forKey: defaultServerIdKey)
        return true
    }

    /// Repairs installs that predate the persisted default-server setting or
    /// contain a default ID for a server that is no longer saved. Existing
    /// active-server state is the least surprising migration choice; new
    /// installs fall back to the first saved server.
    @discardableResult
    private func ensureDefaultServer(preferFirstSavedServer: Bool = false) -> Bool {
        guard let currentDefaultID = defaultServerId else {
            let candidate = preferFirstSavedServer ? servers.first : (activeServer ?? servers.first)
            guard let candidate else { return false }
            defaultServerId = candidate.id
            return true
        }

        guard servers.contains(where: { $0.id == currentDefaultID }) else {
            defaultServerId = (preferFirstSavedServer ? servers.first : (activeServer ?? servers.first))?.id
            return true
        }

        return false
    }

    private func tokenKey(_ id: String) -> String { "accessToken.\(id)" }

    /// Rebuild active content after a successful URL or credential change.
    /// Alias-only edits intentionally leave this untouched.
    func markActiveConnectionChanged() {
        serverConnectionRevision += 1
    }

    /// Returns a server-scoped token and repairs installs created before the
    /// per-server token migration when the active server still has a legacy
    /// token available. The legacy token is only a safe fallback for the
    /// active server; it must never be reused for another saved server.
    func token(for server: ServerConfig, allowLegacyFallback: Bool = false) -> String? {
        if let token = KeychainHelper.get(forKey: tokenKey(server.id)) {
            return token
        }
        guard allowLegacyFallback,
              server.id == activeServerId,
              legacyTokenBelongsTo(server),
              let legacyToken = KeychainHelper.get(forKey: keychainAccessTokenKey) else {
            return nil
        }
        guard KeychainHelper.save(legacyToken, forKey: tokenKey(server.id)) else {
            logger.error("Could not migrate the active server's saved credential")
            return nil
        }
        UserDefaults.standard.set(server.id, forKey: legacyTokenServerIDKey)
        logger.info("Migrated the active server's legacy credential to its server-scoped key")
        return legacyToken
    }

    /// Builds a client whose URL, token, and user ID are permanently tied to
    /// one saved server. Playback and retry code uses this instead of
    /// temporarily repointing `JellyfinClient.shared`, which could otherwise
    /// send a delayed report to whichever server a different route selected.
    func makeClient(for serverID: String) -> JellyfinClient? {
        guard let server = servers.first(where: { $0.id == serverID }),
              let token = token(for: server, allowLegacyFallback: true) else {
            return nil
        }
        return JellyfinClient(
            serverURL: server.url,
            accessToken: token,
            userId: server.userId
        )
    }

    /// Older installs have no marker and are safe to migrate only for the
    /// active server. New activations record the source server whenever they
    /// update the legacy slot.
    private func legacyTokenBelongsTo(_ server: ServerConfig) -> Bool {
        if let sourceServerID = UserDefaults.standard.string(forKey: legacyTokenServerIDKey) {
            return sourceServerID == server.id
        }

        // A pre-marker install can only be migrated when the old server
        // identity is still present and agrees with the saved account. Never
        // infer ownership from "active" alone once more than one server is
        // saved; the global token may belong to any of them.
        guard servers.count == 1,
              let legacyURLString = UserDefaults.standard.string(forKey: userDefaultsServerURLKey),
              let legacyURL = URL(string: legacyURLString),
              let legacyUserID = UserDefaults.standard.string(forKey: userDefaultsUserIdKey),
              legacyUserID == server.userId else {
            return false
        }

        return legacyURL.scheme?.caseInsensitiveCompare(server.url.scheme ?? "") == .orderedSame
            && legacyURL.host?.caseInsensitiveCompare(server.url.host ?? "") == .orderedSame
            && (legacyURL.port ?? defaultPort(for: legacyURL)) == (server.url.port ?? defaultPort(for: server.url))
    }

    private func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    // MARK: - Session lifecycle

    /// Restores the persisted launch session once and coalesces callers that
    /// arrive while that restore is in flight. Later view/window lifecycles
    /// must not repeat the default-server selection over a warm session.
    func restoreSession() async {
        if let sessionRestoreTask {
            await sessionRestoreTask.value
            return
        }
        guard !hasCompletedInitialRestore else { return }

        beginSessionRestore()
        await sessionRestoreTask?.value
    }

    /// App Intents may run before SwiftUI's root view exists. Wait for the
    /// in-flight launch restore when necessary, while leaving an already warm
    /// session alone so a Siri request cannot switch the user back to default.
    func restoreSessionForIntent() async {
        if let sessionRestoreTask {
            await sessionRestoreTask.value
            return
        }
        guard !hasCompletedInitialRestore else { return }

        beginSessionRestore()
        await sessionRestoreTask?.value
    }

    private func beginSessionRestore() {
        guard sessionRestoreTask == nil else { return }

        sessionRestoreTask = Task { @MainActor [weak self] in
            await self?.performRestoreSession()
            self?.hasCompletedInitialRestore = true
            self?.sessionRestoreTask = nil
        }
    }

    private func performRestoreSession() async {
        loadServers()

        // Migrate the legacy single-server session into the list once.
        if servers.isEmpty {
            migrateLegacySession()
        }

        var persistenceChanged = ensureDefaultServer()

        guard let server = defaultServer else {
            if activeServerId != nil {
                activeServerId = nil
                persistenceChanged = true
            }
            if persistenceChanged {
                saveServers()
            }
            reauthServer = nil
            return
        }
        if activeServerId != server.id {
            activeServerId = server.id
            persistenceChanged = true
        }
        if persistenceChanged {
            saveServers()
        }

        // Keep missing non-active credentials visible in diagnostics as well.
        // They remain selectable in Settings and can be re-authenticated, but
        // a multi-server search must never make the omission look like an
        // empty Jellyfin catalog.
        for savedServer in servers where savedServer.id != server.id {
            if token(for: savedServer) == nil {
                logger.error(
                    "Saved server has no readable access token: \(savedServer.url.host ?? "unknown", privacy: .private(mask: .hash))"
                )
            }
        }

        guard let token = token(for: server, allowLegacyFallback: true) else {
            // Keep the saved server visible and prefill its address/user in the
            // auth form. A missing token is a re-authentication case, not a
            // reason to make the user configure the server from scratch.
            reauthServer = server
            logger.error("Session restore could not read the saved access token; re-authentication required")
            return
        }
        reauthServer = nil
        await activate(server, token: token)
    }

    /// Pre multi-server builds stored one server across three UserDefaults
    /// keys + one Keychain entry (with an even older plaintext fallback).
    private func migrateLegacySession() {
        guard let urlString = UserDefaults.standard.string(forKey: userDefaultsServerURLKey),
              let url = URL(string: urlString),
              let userId = UserDefaults.standard.string(forKey: userDefaultsUserIdKey) else { return }

        var token = KeychainHelper.get(forKey: keychainAccessTokenKey)
        if token == nil, let legacy = UserDefaults.standard.string(forKey: legacyUserDefaultsTokenKey) {
            token = legacy
        }
        guard let token else { return }

        let config = ServerConfig(
            id: UUID().uuidString,
            name: url.host ?? "Jellyfin",
            url: url,
            username: UserDefaults.standard.string(forKey: "userName") ?? "User",
            userId: userId
        )
        guard KeychainHelper.save(token, forKey: tokenKey(config.id)) else {
            logger.error("Keychain save failed while migrating legacy session; will retry next launch")
            return
        }
        servers = [config]
        activeServerId = config.id
        defaultServerId = config.id
        saveServers()

        // Scrub every legacy copy only after the new entry is durable.
        UserDefaults.standard.removeObject(forKey: userDefaultsServerURLKey)
        UserDefaults.standard.removeObject(forKey: userDefaultsUserIdKey)
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsTokenKey)
        KeychainHelper.delete(forKey: keychainAccessTokenKey)
        logger.info("Migrated legacy single-server session to multi-server store")
    }

    private func activate(_ server: ServerConfig, token: String) async {
        // Keep the legacy single-server keys in sync for unscoped legacy routes
        // that still read them directly. Multi-server downloads, subtitles, and
        // scoped artwork resolve their own server URL and token explicitly, so
        // temporary server scopes deliberately do not update this mirror.
        await clientConfigurationMutex.lock()
        await configureClient(for: server, token: token, mirrorDefaults: true)
        await clientConfigurationMutex.unlock()
        // Measure the connection in the background so the first play uses a
        // bandwidth-appropriate Auto bitrate (no stall on remote links). Runs
        // on every activation — login, restore, server switch — and retries
        // internally, so one failed probe no longer stands for the session.
        await JellyfinClient.shared.startBandwidthMeasurement()

        self.serverURL = server.url
        self.currentUser = UserDto(id: server.userId, name: server.username, serverID: nil, primaryImageTag: nil)
        self.isAuthenticated = true
    }

    // MARK: - Add / switch / remove

    /// Signs into a server and ADDS it to the saved list (making it active).
    func login(serverURL: URL, username: String, password: String) async throws {
        await JellyfinClient.shared.configure(serverURL: serverURL)

        let result = try await JellyfinClient.shared.authenticate(username: username, password: password)

        if ensureDefaultServer() {
            saveServers()
        }

        if let existing = servers.first(where: { $0.url == serverURL && $0.userId == result.user.id }) {
            // Server is already saved. If there's a live session for it, this is
            // a genuine duplicate add — restore the active client and report it.
            // Otherwise the entry survived a session-expiry/sign-out (token was
            // dropped but the entry kept), so the user is re-authenticating:
            // recover by re-saving the fresh token and reactivating, instead of
            // stranding them on "already connected to that one".
            let hasLiveSession = isAuthenticated
                && activeServerId == existing.id
                && KeychainHelper.get(forKey: tokenKey(existing.id)) != nil
            if hasLiveSession {
                if let current = activeServer, let token = KeychainHelper.get(forKey: tokenKey(current.id)) {
                    await activate(current, token: token)
                }
                throw SessionError.duplicateServer
            }
            guard KeychainHelper.save(result.accessToken, forKey: tokenKey(existing.id)) else {
                await JellyfinClient.shared.clearCredentials()
                throw SessionError.credentialStorageFailed
            }
            activeServerId = existing.id
            saveServers()
            await activate(existing, token: result.accessToken)
            return
        }

        var serverName = serverURL.host ?? "Jellyfin"
        if let info = try? await JellyfinClient.shared.getPublicSystemInfo(), let name = info.serverName {
            serverName = name
        }

        let config = ServerConfig(
            id: UUID().uuidString,
            name: serverName,
            url: serverURL,
            username: result.user.name ?? username,
            userId: result.user.id
        )

        // Persist the token first: if the Keychain rejects it, fail the login
        // visibly rather than leaving a session that vanishes on next launch.
        guard KeychainHelper.save(result.accessToken, forKey: tokenKey(config.id)) else {
            logger.error("Keychain save for access token failed during login")
            await JellyfinClient.shared.clearCredentials()
            throw SessionError.credentialStorageFailed
        }

        servers.append(config)
        if defaultServerId == nil {
            defaultServerId = config.id
        }
        activeServerId = config.id
        saveServers()

        self.logoutReason = nil
        await activate(config, token: result.accessToken)
    }

    /// Switch the active server (no-op if already active or unknown).
    /// Re-point the shared client at the active server + token. Call after an
    /// Add Server probe (which repoints the shared client at the candidate
    /// server) so the live session keeps working when the sheet closes.
    func restoreActiveClient() async {
        await clientConfigurationMutex.lock()
        guard clientScopeStack.isEmpty,
              let server = activeServer,
              let token = token(for: server, allowLegacyFallback: true) else {
            await clientConfigurationMutex.unlock()
            return
        }
        reauthServer = nil
        await configureClient(for: server, token: token, mirrorDefaults: true)
        await clientConfigurationMutex.unlock()
    }

    /// Begins a temporary server-client scope without changing the selected
    /// server in the app chrome. The returned token must be ended by the route
    /// that began it. Scopes are serialized and retain their parent server so
    /// nested title and person routes restore the exact client they inherited.
    func beginServerScope(for serverID: String) async -> ServerClientScopeToken? {
        guard let server = servers.first(where: { $0.id == serverID }),
              let token = token(for: server, allowLegacyFallback: true) else {
            return nil
        }

        await clientConfigurationMutex.lock()
        let scope = clientScopeStack.begin(
            previousServerID: configuredServerID ?? activeServerId
        )
        await configureClient(for: server, token: token, mirrorDefaults: false)
        await clientConfigurationMutex.unlock()
        return scope
    }

    /// Ends a temporary server-client scope and restores its parent. If a
    /// parent disappears before a nested route, the stack is re-linked so the
    /// nested route still restores the parent of that removed scope.
    func endServerScope(_ scope: ServerClientScopeToken) async {
        await clientConfigurationMutex.lock()

        guard let removal = clientScopeStack.end(scope) else {
            await clientConfigurationMutex.unlock()
            return
        }

        if !removal.wasTop {
            await clientConfigurationMutex.unlock()
            return
        }

        await configureClient(
            forServerID: removal.entry.previousServerID,
            mirrorDefaults: clientScopeStack.isEmpty
        )
        await clientConfigurationMutex.unlock()
    }

    func switchServer(to id: String) async {
        guard id != activeServerId, let server = servers.first(where: { $0.id == id }) else { return }
        guard let token = KeychainHelper.get(forKey: tokenKey(server.id)) else {
            // Token was dropped by a past session expiry (the entry was kept so
            // the user could re-authenticate). Prompt a prefilled re-auth
            // instead of silently doing nothing when they tap this server.
            reauthServer = server
            return
        }
        activeServerId = id
        saveServers()
        await activate(server, token: token)
    }

    @discardableResult
    func setDefaultServer(to id: String) -> Bool {
        guard servers.contains(where: { $0.id == id }), defaultServerId != id else { return false }

        let previousDefaultID = defaultServerId
        defaultServerId = id
        guard saveServers() else {
            defaultServerId = previousDefaultID
            return false
        }
        return true
    }

    private func mirrorServerDefaults(_ server: ServerConfig, token: String) {
        UserDefaults.standard.set(server.url.absoluteString, forKey: "serverURL")
        UserDefaults.standard.set(server.userId, forKey: "userId")
        UserDefaults.standard.set(server.username, forKey: "userName")
        _ = KeychainHelper.save(token, forKey: keychainAccessTokenKey)
        UserDefaults.standard.set(server.id, forKey: legacyTokenServerIDKey)
    }

    private func configureClient(for server: ServerConfig, token: String, mirrorDefaults: Bool) async {
        if mirrorDefaults {
            mirrorServerDefaults(server, token: token)
        }
        await JellyfinClient.shared.configure(serverURL: server.url, accessToken: token, userId: server.userId)
        configuredServerID = server.id
    }

    private func configureClient(forServerID serverID: String?, mirrorDefaults: Bool = true) async {
        guard let serverID,
              let server = servers.first(where: { $0.id == serverID }),
              let token = token(for: server, allowLegacyFallback: true) else {
            await JellyfinClient.shared.clearCredentials()
            configuredServerID = nil
            return
        }
        await configureClient(for: server, token: token, mirrorDefaults: mirrorDefaults)
    }

    /// Remove a saved server. Removing the active one activates the next;
    /// removing the last returns to the signed-out state.
    func removeServer(id: String) async {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        let removedDefault = defaultServerId == id
        KeychainHelper.delete(forKey: tokenKey(id))
        servers.remove(at: idx)
        _ = ensureDefaultServer(preferFirstSavedServer: removedDefault)

        if activeServerId == id {
            if let next = servers.first, let token = KeychainHelper.get(forKey: tokenKey(next.id)) {
                activeServerId = next.id
                saveServers()
                await activate(next, token: token)
            } else {
                activeServerId = nil
                saveServers()
                await clientConfigurationMutex.lock()
                await JellyfinClient.shared.clearCredentials()
                configuredServerID = nil
                await clientConfigurationMutex.unlock()
                self.serverURL = nil
                self.currentUser = nil
                self.logoutReason = .userInitiated
                self.isAuthenticated = false
            }
        } else {
            saveServers()
        }
    }

    /// Sign out of the ACTIVE server (removes it from the list). A session
    /// expiry keeps the entry so the user can re-authenticate; it just
    /// drops to signed-out state.
    /// Signs out of the active server.
    ///
    /// Flips the published state synchronously so the UI switches to the login
    /// screen immediately, then does the teardown in ONE ordered task.
    ///
    /// This used to fire two independent tasks -- `removeServer(id:)` and
    /// `clearCredentials()`. Both inherit @MainActor, so removeServer ran first
    /// and, with a second saved server, called `activate(next:)`, which suspends
    /// at `await JellyfinClient.shared.configure(...)`. clearCredentials then
    /// landed in that suspension window and nulled the client the activate had
    /// just configured, before activate resumed and set isAuthenticated = true.
    /// The result was an app that looked signed in but threw notConfigured on
    /// every request until it was force-quit. Sign-out also silently became
    /// "switch to my other server", which is not what the button says.
    func logout(reason: LogoutReason = .userInitiated) {
        self.serverURL = nil
        self.currentUser = nil
        self.logoutReason = reason
        self.reauthServer = nil
        self.isAuthenticated = false
        Task { await teardownSession(reason: reason) }
    }

    private func teardownSession(reason: LogoutReason) async {
        if let active = activeServerId {
            if reason == .sessionExpired {
                // Keep the entry so the user can re-authenticate; just drop
                // the dead token and session state.
                KeychainHelper.delete(forKey: tokenKey(active))
            } else {
                // Drop the entry WITHOUT removeServer's successor-activation.
                // That behaviour is right for "remove this server" in Settings,
                // but signing out should sign out, not hop to another account.
                if let idx = servers.firstIndex(where: { $0.id == active }) {
                    KeychainHelper.delete(forKey: tokenKey(active))
                    servers.remove(at: idx)
                }
                _ = ensureDefaultServer()
                activeServerId = nil
                saveServers()
            }
        }
        // Clear the mirrored global token so a signed-out app can't authorize a
        // download/subtitle fetch with the last session's token.
        KeychainHelper.delete(forKey: keychainAccessTokenKey)
        await clientConfigurationMutex.lock()
        await JellyfinClient.shared.clearCredentials()
        configuredServerID = nil
        await clientConfigurationMutex.unlock()
    }
}

extension SessionManager {
    /// Edits a saved server without disturbing the active shared client until
    /// any changed connection credentials have been verified. Alias-only
    /// changes remain local and do not contact Jellyfin.
    func updateServer(
        id: String,
        nameOverride: String?,
        serverURL: URL,
        username: String,
        password: String?,
        authenticate: ServerEditCoordinator.Authenticator? = nil
    ) async throws {
        guard let index = servers.firstIndex(where: { $0.id == id }) else {
            throw SessionError.serverNotFound
        }

        let current = servers[index]
        let request = ServerEditRequest(
            nameOverride: nameOverride,
            serverURL: serverURL,
            username: username,
            password: password
        )
        let connectionChanged = request.changesConnection(from: current)

        let authenticator: ServerEditCoordinator.Authenticator = authenticate ?? { url, loginUsername, loginPassword in
            let client = JellyfinClient()
            await client.configure(serverURL: url)
            let result = try await client.authenticate(username: loginUsername, password: loginPassword)
            let serverName = try? await client.getPublicSystemInfo().serverName
            return ServerEditAuthentication(
                accessToken: result.accessToken,
                username: result.user.name,
                userId: result.user.id,
                serverName: serverName
            )
        }
        let prepared = try await ServerEditCoordinator.prepare(
            current: current,
            request: request,
            authenticate: authenticator
        )

        let previousToken = token(for: current, allowLegacyFallback: true)
        if let newToken = prepared.accessToken {
            guard KeychainHelper.save(newToken, forKey: tokenKey(id)) else {
                throw SessionError.credentialStorageFailed
            }
        }

        servers[index] = prepared.server
        guard saveServers() else {
            // Roll back both pieces of the record if metadata cannot be
            // persisted after a successful credential write.
            servers[index] = current
            if let previousToken {
                if !KeychainHelper.save(previousToken, forKey: tokenKey(id)) {
                    logger.error("Could not restore the previous credential after server edit rollback")
                }
            } else if !KeychainHelper.delete(forKey: tokenKey(id)) {
                logger.error("Could not remove the replacement credential after server edit rollback")
            }
            throw SessionError.credentialStorageFailed
        }

        guard activeServerId == id else { return }

        // Alias-only edits are local presentation changes. Do not reactivate
        // the shared client or start another bandwidth probe for them.
        guard connectionChanged else { return }

        if let token = token(for: prepared.server, allowLegacyFallback: true) {
            reauthServer = nil
            await activate(prepared.server, token: token)
            markActiveConnectionChanged()
        } else {
            reauthServer = prepared.server
        }
    }
}
