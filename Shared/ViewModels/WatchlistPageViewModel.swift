import Combine
import Foundation

/// One poster on the Watchlist page: on the server, or missing with a tag.
struct WatchlistTile: Identifiable, Equatable {
    let entry: WatchlistEntry
    let libraryItem: BaseItemDto?
    /// Nil exactly when `libraryItem` is non-nil.
    let missingTag: Watchlist.MissingTag?
    /// Requests' poster for a missing title, once it has been looked up.
    var seerrPoster: URL?

    var id: String { entry.id }
    var isMissing: Bool { libraryItem == nil }
}

enum WatchlistHeader: Equatable { case connectCard, synced, needsReconnect, none }

enum WatchlistMenuItem: Equatable { case connectPlex, reconnectPlex, disconnectPlex, removeTitles }

enum WatchlistTileAction: Equatable {
    case openLibrary(BaseItemDto)
    /// The title page for a title the server doesn't have (plugin 0.3.0+).
    case openTitle(WatchlistTitleSeed)
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
    /// The Seerr server and user the shared answers belong to ("server#user").
    private static var cacheOwner: String?

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
    /// Provider details for the Spotlight, by entry id.
    @Published private(set) var spotlightDetails: [String: WatchlistTitleDetails] = [:]
    private var detailsAsked = Set<String>()
    /// Tiles whose remove is on its way.
    @Published private(set) var removingIds = Set<String>()

    private let store: WatchlistStore
    private let service: WatchlistService
    private let seerr: SeerrSession
    private let features: SashimiListsFeatures
    private let injectedLookup: RequestedLookup?
    private var libraryItems: [String: BaseItemDto] = [:]
    /// Seerr's answers this model has seen (a nil value: asked, nothing known).
    private var known: [String: SeerrMediaInfo?] = [:]
    /// Queued or being looked up right now, so a tile that appears twice is asked about once.
    private var requested = Set<String>()
    /// Bumped when the Seerr user changes; a batch started under another one is dropped.
    private var ownerEpoch = 0
    private var pending: [SeerrTarget] = []
    /// The batch being looked up right now.
    private var inFlight: [SeerrTarget] = []
    /// Cut short by `cancelLookups()`: asked again on the next load, since the
    /// grid's visible tiles don't appear again when a cover over the page closes.
    private var interrupted = Set<String>()
    private var drain: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// The entry ids `libraryItems` was last asked for, in order.
    private var queriedIds: [String]?
    /// Bumped by each library query, so an older one that answers late is dropped.
    private var libraryGeneration = 0
    /// Removed on the server, but still in the store's last answer (its reload
    /// failed or hasn't come back): kept off the grid until the server agrees.
    private var removedIds = Set<String>()

    init(store: WatchlistStore = .shared, service: WatchlistService = WatchlistService(),
         seerr: SeerrSession = .shared, features: SashimiListsFeatures = .shared, lookup: RequestedLookup? = nil) {
        self.store = store
        self.service = service
        self.seerr = seerr
        self.features = features
        self.injectedLookup = lookup
        syncCacheOwner()
        // ＋ Add and the title page follow the plugin's answer.
        features.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        // Header and menu read the store; the page redraws when it changes.
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        // @Published fires before the change lands: look again once it has.
        seerr.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.seerrChanged()
        }.store(in: &cancellables)
        // A link, unlink or Plex sync made anywhere changes the entries: the
        // grid follows, with the server's items looked up again.
        store.$watchlist.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.watchlistChanged()
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

    /// Over the Spotlight: "Watchlist · 8 titles".
    var eyebrow: String { "\(WatchlistText.name) · \(ListText.titles(tiles.count))" }

    /// The Spotlight for a tile: Request needs this device signed into Requests.
    func spotlight(for tile: WatchlistTile) -> ListSpotlight {
        ListSpotlight(tile: tile, signedIntoRequests: seerr.client != nil, details: spotlightDetails[tile.id])
    }

    /// The Spotlight moved to this tile: a title the server doesn't have gets
    /// its backdrop and overview from the server's providers (plugin 0.3.0+),
    /// asked once per page.
    func spotlightShown(_ tile: WatchlistTile) async {
        guard features.hasWatchlistV2, tile.isMissing, detailsAsked.insert(tile.id).inserted else { return }
        guard let details = try? await service.details(WatchlistTitleSeed(entry: tile.entry)) else { return }
        spotlightDetails[tile.id] = details
    }

    func load() async {
        async let featuresLoad: Void = features.refresh()
        await store.refresh()
        await featuresLoad
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
        await followEntries(list.entries)
        isLoading = false
        resumeInterruptedLookups()
    }

    private func resumeInterruptedLookups() {
        let cut = interrupted
        interrupted = []
        for tile in tiles {
            if let target = Watchlist.seerrTarget(for: tile.entry), cut.contains(target.id) { tileAppeared(tile) }
        }
    }

    /// Looks up the server's items for these entries and rebuilds the grid,
    /// unless a newer lookup started meanwhile.
    private func followEntries(_ entries: [WatchlistEntry]) async {
        queriedIds = entries.map(\.id)
        libraryGeneration += 1
        let generation = libraryGeneration
        let items = await service.libraryItems(for: entries)
        guard generation == libraryGeneration else { return }
        libraryItems = items
        rebuildTiles()
    }

    private func watchlistChanged() {
        // Before the first load, and once the page is gone, load() decides.
        guard !isLoading, !isGone, let entries = store.watchlist?.entries else { return }
        failed = false // a load that failed here was answered by a later one
        guard entries.map(\.id) != queriedIds else {
            rebuildTiles() // same titles; nothing to look up
            return
        }
        Task { await followEntries(entries) }
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
        interrupted.formUnion((pending + inFlight).map(\.id))
        drain?.cancel()
        drain = nil
        requested = []
        pending = []
        inFlight = []
    }

    /// ＋ Add: the plugin can search (0.3.0+).
    var canAdd: Bool { features.hasWatchlistV2 }

    func action(for tile: WatchlistTile) -> WatchlistTileAction {
        if let item = tile.libraryItem { return .openLibrary(item) }
        if features.hasWatchlistV2 { return .openTitle(WatchlistTitleSeed(entry: tile.entry)) }
        guard let target = Watchlist.seerrTarget(for: tile.entry) else {
            return .explain(WatchlistText.cantLookUp)
        }
        return seerr.client == nil ? .explain(WatchlistText.signIntoRequests) : .openRequest(target)
    }

    func dismissCard() async {
        await store.dismissCard()
    }

    func disconnect() async -> Bool {
        await store.unlink()
    }

    /// True while this tile's remove is on its way: the view dims it.
    func isRemoving(_ tile: WatchlistTile) -> Bool { removingIds.contains(tile.id) }

    /// False only when the server didn't remove it. A second tap while the
    /// first is on its way is ignored. Once the server has removed it, the
    /// tile goes even if the reload after it fails.
    func remove(_ tile: WatchlistTile) async -> Bool {
        guard removingIds.insert(tile.id).inserted else { return true }
        defer { removingIds.remove(tile.id) }
        guard await store.remove(tile.entry) else { return false }
        removedIds.insert(tile.id)
        await followEntries(store.watchlist?.entries ?? [])
        rebuildTiles() // in case a newer lookup took over: the tile still goes now
        return true
    }

    #if DEBUG
    /// For tests: returns when every queued Requested lookup has finished.
    func waitForLookups() async {
        while let running = drain { await running.value }
    }
    #endif

    // MARK: Lookups

    private func drainQueue() async {
        defer { if !Task.isCancelled { drain = nil } }
        while !pending.isEmpty, !Task.isCancelled {
            let batch = pending
            pending = []
            inFlight = batch
            let epoch = ownerEpoch
            let answers = await lookup(batch)
            if !Task.isCancelled { inFlight = [] } // a cancelled batch's slot may be a newer one's now
            syncCacheOwner() // the person may have changed while we waited
            guard !Task.isCancelled else { return }
            // Another person's answers are dropped, but what was queued since is theirs to ask.
            guard epoch == ownerEpoch else { continue }
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
        let all = store.watchlist?.entries ?? []
        removedIds.formIntersection(all.map(\.id)) // the server's list agrees: forget them
        let entries = all.filter { !removedIds.contains($0.id) }
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
            let poster = signedIn ? Watchlist.seerrTarget(for: entry)
                .flatMap { Self.titleCache.entry(for: $0)?.posterPath }
                .flatMap { SeerrImages.poster($0) } : nil
            return WatchlistTile(entry: entry, libraryItem: nil, missingTag: Watchlist.missingTag(badge: badge),
                                 seerrPoster: poster)
        }
    }

    // MARK: Seerr user

    /// Another Seerr user, or none, has no use for the last one's answers
    /// ("Declined" is per person). User ids are per request server, so the
    /// same id on another server is another person.
    private func syncCacheOwner() {
        let owner = seerr.state.user.map { "\(seerr.serverURL?.absoluteString ?? "")#\($0.id)" }
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
