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
    /// Why the last "Switch" didn't happen, while its question waits again.
    @Published private(set) var switchFailure: String?

    private let service: WatchlistService
    private var loadedUserId: String?
    private var loadedServer: URL?
    /// The Plex token a pending switch waits on. In memory only; never logged,
    /// stored or published.
    private var heldToken: (switchId: UUID, token: String)?
    /// Bumped by each load, so an older answer that arrives late is dropped.
    private var refreshGeneration = 0

    init(service: WatchlistService = WatchlistService()) {
        self.service = service
    }

    var isAvailable: Bool { availability == .available }

    /// Which user on which server a call was made for. A result that comes
    /// back for another scope belongs to nobody and is dropped.
    private struct Scope: Equatable {
        let userId: String?
        let server: URL?
    }

    private func currentScope() async -> Scope {
        Scope(userId: await service.client.currentUserId, server: await service.client.currentServerURL)
    }

    /// Reloads the Watchlist. Another user or server first loses everything of
    /// the last one. A failed load keeps what was there: a blip is not "no plugin".
    /// Only the latest load lands: a slower, older one can't put back what a
    /// newer one (after a link, unlink or remove) replaced.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let scope = await currentScope()
        if scope.userId != loadedUserId || scope.server != loadedServer {
            watchlist = nil
            availability = .unknown
            pendingSwitch = nil
            heldToken = nil
            notice = nil
            switchFailure = nil
            loadedUserId = scope.userId
            loadedServer = scope.server
        }
        let loaded: WatchlistResponse?
        do {
            loaded = try await service.load()
        } catch {
            return // Keep the previous values.
        }
        guard await currentScope() == scope, generation == refreshGeneration else { return }
        watchlist = loaded
        availability = loaded == nil ? .unavailable : .available
    }

    func contains(_ ids: WatchlistIds, kind: WatchlistKind) -> Bool {
        guard let entries = watchlist?.entries else { return false }
        return Watchlist.contains(entries, kind: kind, ids: ids)
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
            return result.added ? WatchlistText.added : WatchlistText.alreadyOn
        } catch let error as WatchlistError {
            return error.localizedDescription
        } catch {
            return WatchlistText.couldntAdd
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

    /// Nil: the server couldn't be reached, or the user or server changed while
    /// waiting (the answer belongs to someone else and is dropped).
    func link(token: String, replace: Bool) async -> PlexLinkResult? {
        let scope = await currentScope()
        guard let result = try? await service.client.linkWatchlistPlex(token: token, replace: replace),
              await currentScope() == scope else { return nil }
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
        let scope = await currentScope()
        if !(isAvailable && scope.userId == loadedUserId && scope.server == loadedServer) { await refresh() }
        guard isAvailable, await currentScope() == scope else { return }
        // Someone who disconnected Plex is never reconnected behind their back.
        guard watchlist?.plexOptedOut != true else { return }
        let wasLinked = watchlist?.plex != nil
        let result = await link(token: token, replace: false)
        guard await currentScope() == scope else { return }
        switch result {
        case .linked:
            if !wasLinked { notice = WatchlistText.nowSyncs }
        case .conflict(let current, let new):
            let switchId = UUID()
            heldToken = (switchId, token)
            pendingSwitch = PendingSwitch(id: switchId, currentUsername: current, newUsername: new)
        case .rejected, .plexUnreachable, nil:
            break
        }
    }

    /// False when the switch didn't happen. If the server or Plex couldn't be
    /// reached the question stays, so the same "yes" can be tried again.
    func confirmSwitch() async -> Bool {
        guard let held = heldToken, let question = pendingSwitch, question.id == held.switchId else { return false }
        let scope = await currentScope()
        heldToken = nil
        pendingSwitch = nil
        switchFailure = nil
        let result = await link(token: held.token, replace: true)
        if case .linked = result { return true }
        let unreachable = result == nil || result == .plexUnreachable
        if unreachable, await currentScope() == scope, heldToken == nil, pendingSwitch == nil {
            heldToken = held
            pendingSwitch = question
            switchFailure = WatchlistText.couldntReachPlex
        }
        return false
    }

    func declineSwitch() {
        heldToken = nil
        pendingSwitch = nil
        switchFailure = nil
    }
}
