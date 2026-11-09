import Combine
import Foundation

/// One poster on the Watchlist page: on the server, or missing with a tag.
struct WatchlistTile: Identifiable, Equatable {
    let entry: WatchlistEntry
    let libraryItem: BaseItemDto?
    /// Nil exactly when `libraryItem` is non-nil.
    let missingTag: Watchlist.MissingTag?

    var id: String { entry.id }
    var isMissing: Bool { libraryItem == nil }
}

enum WatchlistHeader: Equatable { case connectCard, synced, needsReconnect, none }

enum WatchlistMenuItem: Equatable { case connectPlex, reconnectPlex, disconnectPlex, removeTitles }

enum WatchlistTileAction: Equatable {
    case openLibrary(BaseItemDto)
    case openRequest(SeerrTarget)
    case explain(String)
}

/// Answers with the Seerr media state of each target; a target that couldn't be
/// looked up is left out of the result.
typealias RequestedLookup = @MainActor ([SeerrTarget]) async -> [String: SeerrMediaInfo?]

/// The Watchlist page. Opening it makes no Seerr calls: "Requested" is looked
/// up lazily, for the tiles that actually appear, a few at a time.
@MainActor
final class WatchlistPageViewModel: ObservableObject {
    /// Seerr's answers, kept for the process so a title is asked about once per
    /// session. Reset, with `failedLookups`, when the Seerr user signs out or changes.
    static var titleCache = SeerrTitleCache()
    /// Titles Seerr couldn't answer for: not retried this session, on any visit.
    private static var failedLookups = Set<String>()
    private static var cacheOwner: Int?

    /// Forgets everything Seerr said. Tests start from here.
    static func resetSharedLookups() {
        titleCache = SeerrTitleCache()
        failedLookups = []
        cacheOwner = nil
    }
    private static let maxConcurrentLookups = 4

    @Published private(set) var tiles: [WatchlistTile] = []
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false
    @Published private(set) var isGone = false

    private let store: WatchlistStore
    private let service: WatchlistService
    private let seerr: SeerrSession
    private let injectedLookup: RequestedLookup?
    private var libraryItems: [String: BaseItemDto] = [:]
    /// Seerr's answers this model has seen (a nil value: asked, nothing known).
    private var known: [String: SeerrMediaInfo?] = [:]
    /// Queued or being looked up right now, so a tile that appears twice is asked about once.
    private var requested = Set<String>()
    /// Bumped when the Seerr user changes; a batch started under another one is dropped.
    private var ownerEpoch = 0
    private var pending: [SeerrTarget] = []
    private var drain: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(store: WatchlistStore = .shared, service: WatchlistService = WatchlistService(),
         seerr: SeerrSession = .shared, lookup: RequestedLookup? = nil) {
        self.store = store
        self.service = service
        self.seerr = seerr
        self.injectedLookup = lookup
        syncCacheOwner()
        // Header and menu read the store; the page redraws when it changes.
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        // @Published fires before the change lands: look again once it has.
        seerr.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.seerrChanged()
        }.store(in: &cancellables)
    }

    var header: WatchlistHeader {
        guard let list = store.watchlist else { return .none }
        guard let plex = list.plex else { return list.cardDismissed ? .none : .connectCard }
        return plex.needsReconnect ? .needsReconnect : .synced
    }

    var menuItems: [WatchlistMenuItem] {
        var items: [WatchlistMenuItem]
        switch store.watchlist?.plex {
        case nil: items = [.connectPlex]
        case let plex? where plex.needsReconnect: items = [.reconnectPlex, .disconnectPlex]
        default: items = [.disconnectPlex]
        }
        if !tiles.isEmpty { items.append(.removeTitles) }
        return items
    }

    var summary: String { "Private · \(ListText.titles(tiles.count))" }

    func load() async {
        await store.refresh()
        if store.availability == .unavailable {
            isGone = true
            failed = false
            tiles = []
            isLoading = false
            return
        }
        guard let list = store.watchlist else {
            failed = true
            isLoading = false
            return
        }
        isGone = false
        failed = false
        libraryItems = await service.libraryItems(for: list.entries)
        rebuildTiles()
        isLoading = false
    }

    /// Called from each tile's `.onAppear`. Only a title missing from the server,
    /// with a TMDB id, while signed into Requests, and not asked about yet, is queued.
    func tileAppeared(_ tile: WatchlistTile) {
        guard seerr.client != nil, tile.isMissing, let target = Watchlist.seerrTarget(for: tile.entry),
              cachedInfo(for: target) == nil, !Self.failedLookups.contains(target.id),
              requested.insert(target.id).inserted else { return }
        pending.append(target)
        if drain == nil {
            drain = Task { [weak self] in await self?.drainQueue() }
        }
    }

    /// Stops looking things up (the page went away). What's queued is dropped and
    /// may be asked again when its tile next appears; answers already in the cache stay.
    func cancelLookups() {
        drain?.cancel()
        drain = nil
        requested = []
        pending = []
    }

    func action(for tile: WatchlistTile) -> WatchlistTileAction {
        if let item = tile.libraryItem { return .openLibrary(item) }
        guard let target = Watchlist.seerrTarget(for: tile.entry) else {
            return .explain("Requests can't look this title up.")
        }
        return seerr.client == nil ? .explain(WatchlistText.signIntoRequests) : .openRequest(target)
    }

    func dismissCard() async {
        await store.dismissCard()
    }

    func disconnect() async -> Bool {
        await store.unlink()
    }

    func remove(_ tile: WatchlistTile) async -> Bool {
        guard await store.remove(tile.entry) else { return false }
        rebuildTiles()
        return true
    }

    /// For tests: returns when every queued Requested lookup has finished.
    func waitForLookups() async {
        while let running = drain { await running.value }
    }

    // MARK: Lookups

    private func drainQueue() async {
        defer { if !Task.isCancelled { drain = nil } }
        while !pending.isEmpty, !Task.isCancelled {
            let batch = pending
            pending = []
            let epoch = ownerEpoch
            let answers = await lookup(batch)
            syncCacheOwner() // the person may have changed while we waited
            guard !Task.isCancelled, epoch == ownerEpoch else { return }
            for (id, info) in answers { known.updateValue(info, forKey: id) }
            for target in batch where !answers.keys.contains(target.id) { Self.failedLookups.insert(target.id) }
            requested.subtract(batch.map(\.id))
            rebuildTiles()
        }
    }

    private func lookup(_ targets: [SeerrTarget]) async -> [String: SeerrMediaInfo?] {
        if let injectedLookup { return await injectedLookup(targets) }
        guard let client = seerr.client else { return [:] }
        let cache = Self.titleCache
        await cache.fill(targets, client: client, maxConcurrent: Self.maxConcurrentLookups)
        var answers: [String: SeerrMediaInfo?] = [:]
        for target in targets {
            if let entry = cache.entry(for: target) { answers.updateValue(entry.mediaInfo, forKey: target.id) }
        }
        return answers
    }

    /// Seerr's answer for a title, if one is known: `.some(nil)` is "asked, no state".
    private func cachedInfo(for target: SeerrTarget) -> SeerrMediaInfo?? {
        if let info = known[target.id] { return .some(info) }
        guard let entry = Self.titleCache.entry(for: target) else { return nil }
        return .some(entry.mediaInfo)
    }

    private func rebuildTiles() {
        let entries = store.watchlist?.entries ?? []
        let userId = seerr.state.user?.id
        let signedIn = seerr.client != nil
        tiles = entries.map { entry in
            if let item = entry.itemId.flatMap({ libraryItems[$0] }) {
                return WatchlistTile(entry: entry, libraryItem: item, missingTag: nil)
            }
            var info: SeerrMediaInfo?
            if signedIn, let target = Watchlist.seerrTarget(for: entry), let answer = cachedInfo(for: target) {
                info = answer
            }
            let badge = info.map { SeerrBadge(mediaInfo: $0, userId: userId) }
            return WatchlistTile(entry: entry, libraryItem: nil, missingTag: Watchlist.missingTag(badge: badge))
        }
    }

    // MARK: Seerr user

    /// Another Seerr user, or none, has no use for the last one's answers
    /// ("Declined" is per person).
    private func syncCacheOwner() {
        let owner = seerr.state.user?.id
        guard owner != Self.cacheOwner else { return }
        Self.cacheOwner = owner
        Self.titleCache = SeerrTitleCache()
        Self.failedLookups = []
        known = [:]
        requested = []
        pending = []
        ownerEpoch += 1
    }

    private func seerrChanged() {
        syncCacheOwner()
        if !tiles.isEmpty { rebuildTiles() }
    }
}
