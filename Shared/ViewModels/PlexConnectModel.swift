import Foundation

/// Connect Plex for the Watchlist: its own Plex sign-in, independent of
/// Requests, so it works with or without a Requests account. The token is held
/// in memory only while a switch question waits, and is never logged, stored
/// or shown.
@MainActor
final class PlexConnectModel: ObservableObject {
    enum State: Equatable {
        case idle
        case awaitingPlex(code: String)
        case linking
        case linked
        case conflict(currentUsername: String, newUsername: String?)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Something to tell the person beside the current state: why the last
    /// "Switch" didn't happen.
    @Published private(set) var message: String?
    /// How many PIN checks have started, so Plex's web page can give the poll
    /// one more after it closes.
    private(set) var pinChecks = 0

    /// The PIN of a Connect Plex still waiting, kept so it can be collected
    /// after a relaunch: its id, code, expiry and who started it (Jellyfin
    /// user and server), never a token.
    static let pendingPinKey = "watchlist.pendingPlexPin"

    /// PINs this process is polling or collecting right now, so a second
    /// model (Settings, the page, launch) never links the same PIN twice.
    private static var pinsInHand = Set<Int>()

    private let store: WatchlistStore
    private let defaults: UserDefaults
    private let pollInterval: Duration
    private let pinLifetime: Duration
    private let now: () -> Date
    /// The token a switch question waits on, and whose Watchlist it was for.
    private var heldToken: HeldToken?

    private struct HeldToken {
        let token: String
        let userId: String?
        let server: URL?
    }
    private var flow: Task<Void, Never>?
    /// Bumped by `cancel()`, so a `begin` that was waiting on plex.tv when
    /// the person cancelled doesn't bring the code back.
    private var cancelEpoch = 0

    init(store: WatchlistStore = .shared, defaults: UserDefaults = .standard,
         pollInterval: Duration = .seconds(2), pinLifetime: Duration = .seconds(15 * 60),
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.defaults = defaults
        self.pollInterval = pollInterval
        self.pinLifetime = pinLifetime
        self.now = now
    }

    /// The one line shown while a Connect Plex is under way; nil otherwise.
    var progressText: String? {
        switch state {
        case .awaitingPlex: return WatchlistText.waitingForPlex
        case .linking: return WatchlistText.connecting
        default: return nil
        }
    }

    var isWaiting: Bool {
        if case .awaitingPlex = state { return true }
        return false
    }

    private var plexClient: PlexPinClient {
        PlexPinClient(clientIdentifier: PlexClientIdentity.identifier(defaults: defaults))
    }

    /// Step 1: get a PIN. The TV shows its code (`strong: false`); the phone
    /// opens Plex's sign-in page with it (`strong: true`).
    func begin(strong: Bool) async -> PlexPin? {
        heldToken = nil
        message = nil
        let epoch = cancelEpoch
        do {
            let pin = try await plexClient.createPin(strong: strong)
            let owner = await store.currentOwner()
            guard epoch == cancelEpoch else { return nil } // cancelled meanwhile
            state = .awaitingPlex(code: pin.code)
            savePending(pin, owner: owner)
            return pin
        } catch {
            if epoch == cancelEpoch { state = .failed(WatchlistText.couldntReachPlex) }
            return nil
        }
    }

    /// Step 2: wait for the person to link the code, then link the Watchlist.
    func complete(pin: PlexPin) async {
        Self.pinsInHand.insert(pin.id)
        defer { Self.pinsInHand.remove(pin.id) }
        let token = await plexClient.waitForToken(
            pinId: pin.id,
            deadline: .now + pinLifetime,
            interval: pollInterval,
            isWaiting: { self.state == .awaitingPlex(code: pin.code) },
            onCheck: { self.pinChecks += 1 }
        )
        guard let token else {
            if !Task.isCancelled, state == .awaitingPlex(code: pin.code) {
                state = .failed(WatchlistText.codeExpired)
                clearPending()
            }
            return
        }
        let owner = await store.currentOwner()
        guard state == .awaitingPlex(code: pin.code) else { return } // Cancelled meanwhile.
        state = .linking
        let result = await store.link(token: token, replace: false)
        guard state == .linking else { return } // Cancelled meanwhile.
        apply(result, token: token, owner: owner)
    }

    /// Collects a PIN begun before the app was relaunched (or suspended until
    /// its flow was gone): one check, no long poll. Linked → the Watchlist is
    /// linked; another account → the switch question; not linked yet → left
    /// for later, until it expires. A PIN started by another Jellyfin user or
    /// on another server, or an expired one, is dropped without a network call.
    func resumePendingIfAny() async {
        guard state == .idle, let pending = loadPending() else { return }
        let owner = await store.currentOwner()
        guard pending.expiresAt > now(), let userId = owner.userId, pending.userId == userId,
              let server = owner.server, pending.serverURL == server.absoluteString else {
            clearPending()
            return
        }
        guard Self.pinsInHand.insert(pending.pinId).inserted else { return }
        defer { Self.pinsInHand.remove(pending.pinId) }
        guard let token = try? await plexClient.checkPin(id: pending.pinId).authToken, !token.isEmpty,
              state == .idle, loadPending()?.pinId == pending.pinId else { return }
        state = .linking
        let result = await store.link(token: token, replace: false)
        guard state == .linking else { return }
        if result == nil || result == .plexUnreachable {
            // Nothing was decided: try again on the next resume.
            state = .idle
            return
        }
        apply(result, token: token, owner: owner)
    }

    /// The tvOS flow in one call: show a code and wait for it.
    func startCodeFlow() {
        flow?.cancel()
        flow = Task {
            guard let pin = await begin(strong: false) else { return }
            await complete(pin: pin)
        }
    }

    /// "Yes" to the switch question, with the token held from `complete`.
    func confirmSwitch() async {
        guard case .conflict = state, let held = heldToken else { return }
        let owner = await store.currentOwner()
        guard owner.userId == held.userId, owner.server == held.server else {
            // Asked for another user or server: their token is never sent here.
            cancel()
            return
        }
        let token = held.token
        let question = state
        message = nil
        state = .linking
        let result = await store.link(token: token, replace: true)
        guard state == .linking else { return }
        if result == nil || result == .plexUnreachable {
            // The same "yes" can be tried again, and the person is told why.
            state = question
            message = WatchlistText.couldntReachPlex
            return
        }
        apply(result, token: token, owner: owner)
    }

    func cancel() {
        cancelEpoch += 1
        flow?.cancel()
        flow = nil
        heldToken = nil
        message = nil
        state = .idle
        clearPending()
    }

    func webSignInURL(for pin: PlexPin) -> URL {
        PlexPinClient.webSignInURL(
            clientIdentifier: PlexClientIdentity.identifier(defaults: defaults),
            code: pin.code
        )
    }

    private func apply(_ result: PlexLinkResult?, token: String,
                       owner: (userId: String?, server: URL?)) {
        heldToken = nil
        switch result {
        case .linked:
            state = .linked
        case .conflict(let current, let new):
            // The PIN stays saved until the question is answered, so a
            // relaunch asks it again.
            heldToken = HeldToken(token: token, userId: owner.userId, server: owner.server)
            state = .conflict(currentUsername: current, newUsername: new)
            return
        case .rejected:
            state = .failed(WatchlistText.plexRejected)
        case .plexUnreachable:
            state = .failed(WatchlistText.couldntReachPlex)
        case nil:
            state = .failed(WatchlistText.couldntReachServer)
        }
        clearPending()
    }

    // MARK: Pending PIN

    private struct PendingPin: Codable {
        let pinId: Int
        let code: String
        let expiresAt: Date
        let userId: String?
        let serverURL: String?
    }

    private func savePending(_ pin: PlexPin, owner: (userId: String?, server: URL?)) {
        let pending = PendingPin(pinId: pin.id, code: pin.code,
                                 expiresAt: now().addingTimeInterval(Self.seconds(pinLifetime)),
                                 userId: owner.userId, serverURL: owner.server?.absoluteString)
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: Self.pendingPinKey)
    }

    private func loadPending() -> PendingPin? {
        defaults.data(forKey: Self.pendingPinKey).flatMap { try? JSONDecoder().decode(PendingPin.self, from: $0) }
    }

    private func clearPending() {
        defaults.removeObject(forKey: Self.pendingPinKey)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
