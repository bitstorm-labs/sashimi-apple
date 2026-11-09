import Foundation

/// The current user's Watchlist, shared by every screen.
@MainActor
final class WatchlistStore: ObservableObject {
    static let shared = WatchlistStore()

    enum Availability: Equatable { case unknown, available, unavailable }

    /// A Plex account that differs from the one the Watchlist syncs with. The
    /// token waiting on the answer is held privately by the store.
    struct PendingSwitch: Identifiable, Equatable {
        let id: UUID
        let currentUsername: String
        let newUsername: String?
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var watchlist: WatchlistResponse?
    @Published var pendingSwitch: PendingSwitch?
    @Published var notice: String?

    private let service: WatchlistService
    private var loadedUserId: String?
    private var loadedServer: URL?
    /// The Plex token a pending switch waits on. In memory only; never logged,
    /// stored or published.
    private var heldToken: (switchId: UUID, token: String)?

    init(service: WatchlistService = WatchlistService()) {
        self.service = service
    }

    var isAvailable: Bool { availability == .available }

    /// Reloads the Watchlist. Another user or server first loses everything of
    /// the last one. A failed load keeps what was there: a blip is not "no plugin".
    func refresh() async {
        let userId = await service.client.currentUserId
        let server = await service.client.currentServerURL
        if userId != loadedUserId || server != loadedServer {
            watchlist = nil
            availability = .unknown
            pendingSwitch = nil
            heldToken = nil
            notice = nil
            loadedUserId = userId
            loadedServer = server
        }
        do {
            if let loaded = try await service.load() {
                watchlist = loaded
                availability = .available
            } else {
                watchlist = nil
                availability = .unavailable
            }
        } catch {
            // Keep the previous values.
        }
    }

    func contains(_ ids: WatchlistIds) -> Bool {
        guard let entries = watchlist?.entries else { return false }
        return Watchlist.contains(entries, ids: ids)
    }

    func ids(for item: BaseItemDto) async -> WatchlistIds? {
        await service.ids(for: item)
    }

    func add(_ item: BaseItemDto) async -> String {
        await added { try await service.add(item) }
    }

    func add(_ target: SeerrTarget, year: Int?) async -> String {
        await added { try await service.add(target, year: year) }
    }

    private func added(_ request: () async throws -> WatchlistAddResponse) async -> String {
        do {
            let result = try await request()
            await refresh()
            return result.added ? "Added to Watchlist" : "Already on your Watchlist"
        } catch let error as WatchlistError {
            return error.localizedDescription
        } catch {
            return "Couldn't add to Watchlist"
        }
    }

    func remove(_ entry: WatchlistEntry) async -> Bool {
        do {
            try await service.remove(entry)
        } catch {
            return false
        }
        await refresh()
        return true
    }

    func dismissCard() async {
        do {
            try await service.client.dismissWatchlistCard()
        } catch {
            return
        }
        await refresh()
    }

    /// Nil: the server couldn't be reached.
    func link(token: String, replace: Bool) async -> PlexLinkResult? {
        guard let result = try? await service.client.linkWatchlistPlex(token: token, replace: replace) else { return nil }
        if case .linked = result { await refresh() }
        return result
    }

    func unlink() async -> Bool {
        do {
            try await service.client.unlinkWatchlistPlex()
        } catch {
            return false
        }
        await refresh()
        return true
    }

    /// Links the Plex account the user just signed into Requests with. Silent
    /// unless it newly links or finds a different account already linked.
    func autoLink(token: String) async {
        let userId = await service.client.currentUserId
        if !(isAvailable && userId == loadedUserId) { await refresh() }
        guard isAvailable else { return }
        let wasLinked = watchlist?.plex != nil
        switch await link(token: token, replace: false) {
        case .linked:
            if !wasLinked { notice = WatchlistText.nowSyncs }
        case .conflict(let current, let new):
            let switchId = UUID()
            heldToken = (switchId, token)
            pendingSwitch = PendingSwitch(id: switchId, currentUsername: current, newUsername: new)
        case .rejected, nil:
            break
        }
    }

    func confirmSwitch() async -> Bool {
        guard let held = heldToken, pendingSwitch?.id == held.switchId else { return false }
        heldToken = nil
        pendingSwitch = nil
        guard case .linked = await link(token: held.token, replace: true) else { return false }
        return true
    }

    func declineSwitch() {
        heldToken = nil
        pendingSwitch = nil
    }
}
