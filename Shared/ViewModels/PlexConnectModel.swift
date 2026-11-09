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

    private let store: WatchlistStore
    private let defaults: UserDefaults
    private let pollInterval: Duration
    private let pinLifetime: Duration
    private var heldToken: String?
    private var flow: Task<Void, Never>?

    init(store: WatchlistStore = .shared, defaults: UserDefaults = .standard,
         pollInterval: Duration = .seconds(2), pinLifetime: Duration = .seconds(15 * 60)) {
        self.store = store
        self.defaults = defaults
        self.pollInterval = pollInterval
        self.pinLifetime = pinLifetime
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
        do {
            let pin = try await plexClient.createPin(strong: strong)
            state = .awaitingPlex(code: pin.code)
            return pin
        } catch {
            state = .failed(WatchlistText.couldntReachPlex)
            return nil
        }
    }

    /// Step 2: wait for the person to link the code, then link the Watchlist.
    func complete(pin: PlexPin) async {
        let token = await plexClient.waitForToken(
            pinId: pin.id,
            deadline: .now + pinLifetime,
            interval: pollInterval,
            isWaiting: { self.state == .awaitingPlex(code: pin.code) }
        )
        guard let token else {
            if !Task.isCancelled, state == .awaitingPlex(code: pin.code) {
                state = .failed("The Plex code expired. Try again.")
            }
            return
        }
        state = .linking
        let result = await store.link(token: token, replace: false)
        guard state == .linking else { return } // Cancelled meanwhile.
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
        state = .linking
        let result = await store.link(token: token, replace: true)
        guard state == .linking else { return }
        if result == nil || result == .plexUnreachable {
            // The same "yes" can be tried again.
            state = question
            return
        }
        apply(result, token: token)
    }

    func cancel() {
        flow?.cancel()
        flow = nil
        heldToken = nil
        state = .idle
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
            heldToken = token
            state = .conflict(currentUsername: current, newUsername: new)
        case .rejected:
            state = .failed("Plex didn't accept that sign-in. Try again.")
        case .plexUnreachable:
            state = .failed(WatchlistText.couldntReachPlex)
        case nil:
            state = .failed("Couldn't reach your server. Try again.")
        }
    }
}
