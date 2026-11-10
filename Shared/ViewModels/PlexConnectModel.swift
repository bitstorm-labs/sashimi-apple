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
    /// after a relaunch: its id, code and expiry only, never a token.
    static let pendingPinKey = "watchlist.pendingPlexPin"

    /// PINs this process is polling or collecting right now, so a second
    /// model (Settings, the page, launch) never links the same PIN twice.
    private static var pinsInHand = Set<Int>()

    private let store: WatchlistStore
    private let defaults: UserDefaults
    private let pollInterval: Duration
    private let pinLifetime: Duration
    private let now: () -> Date
    private var heldToken: String?
    private var flow: Task<Void, Never>?

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
        do {
            let pin = try await plexClient.createPin(strong: strong)
            state = .awaitingPlex(code: pin.code)
            savePending(pin)
            return pin
        } catch {
            state = .failed(WatchlistText.couldntReachPlex)
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
        state = .linking
        let result = await store.link(token: token, replace: false)
        guard state == .linking else { return } // Cancelled meanwhile.
        apply(result, token: token)
    }

    /// Collects a PIN begun before the app was relaunched (or suspended until
    /// its flow was gone): one check, no long poll. Linked → the Watchlist is
    /// linked; another account → the switch question; not linked yet → left
    /// for later, until it expires.
    func resumePendingIfAny() async {
        guard state == .idle, let pending = loadPending() else { return }
        guard pending.expiresAt > now() else {
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
        apply(result, token: token)
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
        guard case .conflict = state, let token = heldToken else { return }
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
        apply(result, token: token)
    }

    func cancel() {
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

    private func apply(_ result: PlexLinkResult?, token: String) {
        heldToken = nil
        switch result {
        case .linked:
            state = .linked
        case .conflict(let current, let new):
            // The PIN stays saved until the question is answered, so a
            // relaunch asks it again.
            heldToken = token
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
    }

    private func savePending(_ pin: PlexPin) {
        let pending = PendingPin(pinId: pin.id, code: pin.code,
                                 expiresAt: now().addingTimeInterval(Self.seconds(pinLifetime)))
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
