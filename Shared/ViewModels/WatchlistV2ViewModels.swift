import Combine
import Foundation

/// Whether the server's Sashimi Lists plugin has Watchlist v2 (0.3.0+: ＋ Add,
/// the title page, the Requests address), and the Requests address it sets.
/// Asked when a server session starts, when Requests settings open, and when
/// the Watchlist page loads.
@MainActor
final class SashimiListsFeatures: ObservableObject {
    static let shared = SashimiListsFeatures()

    enum Availability: Equatable { case unknown, available, unavailable }

    @Published private(set) var availability: Availability = .unknown

    private let service: WatchlistService
    private let seerr: SeerrSession

    init(service: WatchlistService = WatchlistService(), seerr: SeerrSession = .shared) {
        self.service = service
        self.seerr = seerr
    }

    var hasWatchlistV2: Bool { availability == .available }

    /// A 404 (older plugin, or none) is "no v2, no server address". Any other
    /// failure (offline, not signed in) changes nothing: the last answer stands.
    func refresh() async {
        let config: SashimiListsConfig?
        do {
            config = try await service.config()
        } catch {
            return
        }
        availability = config == nil ? .unavailable : .available
        await seerr.setServerManagedAddress(config?.requestsURL)
    }
}

/// ＋ Add's search (design §2): one query, two groups. Typing searches after a
/// short pause (2+ characters); `searchNow()` searches at once (Apple TV's
/// keyboard). A newer query cancels an older one, whose answer is dropped.
@MainActor
final class WatchlistSearchModel: ObservableObject {
    enum Phase: Equatable {
        case idle, searching, results
        /// The plugin is older than 0.3.0.
        case unavailable
        case failed
    }

    @Published var text = "" {
        didSet { if text != oldValue { scheduleSearch() } }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var onServer: [WatchlistSearchHit] = []
    @Published private(set) var notOnServer: [WatchlistSearchHit] = []
    /// Added from here this time (hit ids).
    @Published private(set) var addedIds = Set<String>()
    @Published private(set) var addingIds = Set<String>()

    static let minimumLength = 2

    private let service: WatchlistService
    private let store: WatchlistStore
    private let debounce: Duration
    private var task: Task<Void, Never>?

    init(service: WatchlistService = WatchlistService(), store: WatchlistStore = .shared,
         debounce: Duration = .milliseconds(350)) {
        self.service = service
        self.store = store
        self.debounce = debounce
    }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isEmpty: Bool { onServer.isEmpty && notOnServer.isEmpty }

    func isAdded(_ hit: WatchlistSearchHit) -> Bool { hit.onWatchlist || addedIds.contains(hit.id) }

    func isAdding(_ hit: WatchlistSearchHit) -> Bool { addingIds.contains(hit.id) }

    private func scheduleSearch() {
        start(after: debounce)
    }

    func searchNow() {
        start(after: .zero)
    }

    private func start(after delay: Duration) {
        task?.cancel()
        let query = query
        guard query.count >= Self.minimumLength else {
            task = nil
            phase = .idle
            onServer = []
            notOnServer = []
            return
        }
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.run(query)
        }
    }

    private func run(_ query: String) async {
        phase = .searching
        do {
            let response = try await service.search(query)
            guard !Task.isCancelled else { return }
            guard let response else {
                phase = .unavailable
                return
            }
            onServer = response.onServer
            notOnServer = response.notOnServer
            phase = .results
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
        }
    }

    /// ＋: adds the title as the hit describes it. Never requests it.
    func add(_ hit: WatchlistSearchHit) async -> Bool {
        guard !isAdded(hit), addingIds.insert(hit.id).inserted else { return true }
        defer { addingIds.remove(hit.id) }
        do {
            _ = try await service.add(hit.newEntry)
        } catch {
            return false
        }
        addedIds.insert(hit.id)
        await store.refresh()
        return true
    }

    #if DEBUG
    /// For tests: returns when the current search has answered.
    func waitForSearch() async {
        await task?.value
    }
    #endif
}

/// The page for a title the server doesn't have (design §3): what the search
/// hit or Watchlist entry knows at once, the provider's details when they
/// arrive, the Watchlist toggle, and Request (with a Requests sign-in).
@MainActor
final class WatchlistTitleModel: ObservableObject {
    enum RequestButton: Equatable {
        /// No TMDB number: Requests can't look it up.
        case hidden
        case signIn
        case loading
        /// A movie: one press.
        case request
        /// A show: Requests' season picker.
        case chooseSeasons
        /// "Requested · waiting for approval", "Coming soon"…
        case status(String)
    }

    let seed: WatchlistTitleSeed
    @Published private(set) var details: WatchlistTitleDetails?
    @Published private(set) var isLoading = true
    /// The server answered that it has the title: the library page replaces this one.
    @Published private(set) var libraryItem: BaseItemDto?
    @Published private(set) var entryId: String?
    @Published private(set) var isToggling = false
    @Published private(set) var seerrModel: SeerrDetailModel?
    @Published var errorMessage: String?

    private let service: WatchlistService
    private let store: WatchlistStore
    private let seerr: SeerrSession
    private var seerrChanges: AnyCancellable?
    private var sessionChanges: AnyCancellable?

    init(seed: WatchlistTitleSeed, service: WatchlistService = WatchlistService(), store: WatchlistStore = .shared,
         seerr: SeerrSession = .shared) {
        self.seed = seed
        self.service = service
        self.store = store
        self.seerr = seerr
        entryId = seed.watchlistEntryId
        // A Requests sign-in made from this page shows Request when it lands.
        sessionChanges = seerr.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { await self?.loadRequestState() }
        }
    }

    var title: String { details?.title ?? seed.title }
    var posterURL: URL? { details?.posterURL ?? seed.posterURL }
    var backdropURL: URL? { details?.backdropURL }
    var overview: String? { details?.overview.flatMap { $0.isEmpty ? nil : $0 } }
    var isOnWatchlist: Bool { entryId != nil }

    /// "2025 · 2h 17m · R", or "2017 · 4 seasons · TV-MA".
    var metaLine: String {
        var parts: [String] = []
        if let year = details?.year ?? seed.year { parts.append(String(year)) }
        if let minutes = details?.runtimeMinutes, minutes > 0 {
            parts.append(DateFormatting.formatRuntime(Int64(minutes) * 600_000_000) ?? "")
        }
        if let seasons = details?.seasonCount, seasons > 0 { parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons") }
        if let rating = details?.officialRating, !rating.isEmpty { parts.append(rating) }
        if parts.isEmpty { parts.append(seed.kind == .movie ? "Movie" : "Show") }
        return parts.joined(separator: " · ")
    }

    /// "Horror · Thriller · ★ 7.6".
    var genreLine: String? {
        var parts = details?.genres ?? []
        if let rating = details?.communityRating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var sourceLine: String? { details?.source.map(WatchlistV2Text.detailsFrom) }

    private var ids: WatchlistIds { details?.ids ?? seed.ids }

    var seerrTarget: SeerrTarget? {
        guard let raw = ids.tmdb, let tmdbId = Int(raw) else { return nil }
        return SeerrTarget(kind: seed.kind == .movie ? .movie : .tv, tmdbId: tmdbId, title: title)
    }

    var requestButton: RequestButton {
        guard seerrTarget != nil else { return .hidden }
        guard seerr.client != nil else { return .signIn }
        switch seerrModel?.action {
        case .request?: return .request
        case .chooseSeasons?: return .chooseSeasons
        case .status(let text)?: return .status(text)
        case .loading?, .failed?, nil: return .loading
        }
    }

    func load() async {
        isLoading = true
        do {
            if let details = try await service.details(seed) {
                self.details = details
                entryId = details.onWatchlist ? details.watchlistEntryId : nil
                if let itemId = details.itemId {
                    libraryItem = try? await service.client.getItem(itemId: itemId)
                }
            }
        } catch {
            // The page keeps what the seed knows; the toggle still works.
        }
        isLoading = false
        await loadRequestState()
    }

    /// Requests' state for the title, with this device's own Seerr session.
    func loadRequestState() async {
        guard let target = seerrTarget, seerr.client != nil else {
            seerrModel = nil
            seerrChanges = nil
            return
        }
        let model = SeerrDetailModel(target: target, session: seerr)
        seerrChanges = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        seerrModel = model
        await model.load()
    }

    func requestMovie() async {
        await seerrModel?.requestMovie()
        errorMessage = seerrModel?.errorMessage
    }

    /// Add to Watchlist / ✓ On Watchlist. Adding never requests the title.
    func toggleWatchlist() async -> Bool {
        guard !isToggling else { return true }
        isToggling = true
        defer { isToggling = false }
        do {
            if let entryId {
                try await service.remove(entryId: entryId)
                self.entryId = nil
            } else {
                let response = try await service.add(newEntry)
                entryId = response.entry.id
            }
        } catch {
            return false
        }
        await store.refresh()
        return true
    }

    private var newEntry: NewWatchlistEntry {
        NewWatchlistEntry(type: details?.kind ?? seed.kind, title: title, year: details?.year ?? seed.year,
                          posterUrl: posterURL?.absoluteString, tmdbId: ids.tmdb, tvdbId: ids.tvdb, imdbId: ids.imdb)
    }
}

enum WatchlistV2Text {
    static let add = "Add"
    static let addTitle = "Add to Watchlist"
    static let added = "Added"
    static let onWatchlist = "On Watchlist"
    static let onYourServer = "On your server"
    static let notOnServer = "Not on server"
    static let notOnYourServer = "Not on your server"
    static let searchPrompt = "Search movies and shows"
    static let noResults = "No results"
    static let couldntSearch = "Couldn't search. Try again."
    static let searchUnavailable = "This server can't search for titles to add yet."
    static let typeToSearch = "Type at least two letters."
    static let requested = "Requested"
    static let detailsUnavailable = "Details aren't available"
    static let couldntChange = "Couldn't change the Watchlist"
    static let setByYourServer = "Set by your server"
    static let requestsServer = "Requests server"

    static func detailsFrom(_ source: String) -> String { "Details from \(source)" }
}
