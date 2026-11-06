import Foundation

/// One Discover row: a slider's titles so far and where its paging is.
struct SeerrDiscoverRow: Identifiable, Equatable {
    let slider: SeerrDiscoverSlider
    var items: [SeerrSearchItem]
    var page: Int
    var totalPages: Int

    var id: String { slider.id }
    var title: String { slider.title }
    var canLoadMore: Bool { slider != .recentRequests && page < totalPages }
}

/// The Discover section of the Requests page (#845), Seerr web's Discover:
/// Recent Requests, Trending, Popular and Upcoming Movies and Series, and the
/// Plex Watchlist. Rows that come back empty (a watchlist the account
/// doesn't have, say) are left out. Every poster carries Seerr's badge.
@MainActor
final class SeerrDiscoverModel: ObservableObject {
    @Published private(set) var rows: [SeerrDiscoverRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    /// Seerr web's Recent Requests slider takes ten.
    static let recentRequestsCount = 10

    private let session: SeerrSession
    private let titles = SeerrTitleCache()
    private var loadingMore: Set<SeerrDiscoverSlider> = []

    init(session: SeerrSession = .shared) {
        self.session = session
    }

    func load() async {
        guard let client = session.client else {
            rows = []
            hasLoaded = true
            return
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        let userId = session.state.user?.id
        var firstError: Error?
        let loaded = await withTaskGroup(of: (SeerrDiscoverSlider, Result<SeerrDiscoverRow, Error>).self) { group in
            for slider in SeerrDiscoverSlider.allCases {
                group.addTask { [titles] in
                    do {
                        return (slider, .success(try await Self.firstPage(slider, client: client, titles: titles, userId: userId)))
                    } catch {
                        return (slider, .failure(error))
                    }
                }
            }
            var loaded: [SeerrDiscoverSlider: SeerrDiscoverRow] = [:]
            for await (slider, result) in group {
                switch result {
                case .success(let row): loaded[slider] = row
                case .failure(let error): firstError = firstError ?? error
                }
            }
            return loaded
        }
        guard !Task.isCancelled else { return }
        rows = SeerrDiscoverSlider.allCases.compactMap { loaded[$0] }.filter { !$0.items.isEmpty }
        if rows.isEmpty, let firstError, !(firstError is CancellationError) {
            errorMessage = firstError.localizedDescription
            await session.handle(firstError)
        } else {
            errorMessage = nil
        }
    }

    /// Paging: call as each poster appears; the row's next page loads when
    /// it's among the last few.
    func loadMoreIfNeeded(_ slider: SeerrDiscoverSlider, after item: SeerrSearchItem) async {
        guard let rowIndex = rows.firstIndex(where: { $0.slider == slider }),
              rows[rowIndex].canLoadMore, !loadingMore.contains(slider),
              let index = rows[rowIndex].items.firstIndex(where: { $0.id == item.id }),
              index >= rows[rowIndex].items.count - 5,
              let client = session.client else { return }
        loadingMore.insert(slider)
        defer { loadingMore.remove(slider) }
        let next = rows[rowIndex].page + 1
        guard let page = try? await client.discover(slider, page: next) else { return }
        let items = await Self.items(for: page.results, slider: slider, client: client, titles: titles, userId: session.state.user?.id)
        guard let current = rows.firstIndex(where: { $0.slider == slider }) else { return }
        let known = Set(rows[current].items.map(\.id))
        rows[current].items += items.filter { !known.contains($0.id) }
        rows[current].page = page.page
        rows[current].totalPages = page.totalPages
    }

    // MARK: Private

    private static func firstPage(
        _ slider: SeerrDiscoverSlider,
        client: SeerrClient,
        titles: SeerrTitleCache,
        userId: Int?
    ) async throws -> SeerrDiscoverRow {
        if slider == .recentRequests {
            let page = try await client.requestPage(filter: .all, take: recentRequestsCount, skip: 0, requestedBy: nil)
            await titles.fill(for: page.results, client: client)
            let results = page.results.compactMap { request -> SeerrSearchResult? in
                guard let target = SeerrTitleCache.target(for: request) else { return nil }
                let known = titles.entry(for: target)
                return SeerrSearchResult(
                    tmdbId: target.tmdbId,
                    kind: target.kind,
                    title: known?.title ?? "Unknown title",
                    posterPath: known?.posterPath,
                    mediaInfo: request.media ?? known?.mediaInfo
                )
            }
            return SeerrDiscoverRow(slider: slider, items: unique(results, userId: userId), page: 1, totalPages: 1)
        }
        let page = try await client.discover(slider)
        let items = await items(for: page.results, slider: slider, client: client, titles: titles, userId: userId)
        return SeerrDiscoverRow(slider: slider, items: items, page: page.page, totalPages: page.totalPages)
    }

    /// The watchlist has no posters or media state: they come from each
    /// title's details, as on the website.
    private static func items(
        for results: [SeerrSearchResult],
        slider: SeerrDiscoverSlider,
        client: SeerrClient,
        titles: SeerrTitleCache,
        userId: Int?
    ) async -> [SeerrSearchItem] {
        guard slider == .watchlist else { return unique(results, userId: userId) }
        await titles.fill(results.map(SeerrTarget.init), client: client)
        let filled = results.map { result -> SeerrSearchResult in
            guard let known = titles.entry(for: SeerrTarget(result)) else { return result }
            var result = result
            if result.posterPath == nil { result.posterPath = known.posterPath }
            if result.mediaInfo == nil { result.mediaInfo = known.mediaInfo }
            if result.title.isEmpty { result.title = known.title }
            return result
        }
        return unique(filled, userId: userId)
    }

    private static func unique(_ results: [SeerrSearchResult], userId: Int?) -> [SeerrSearchItem] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }.map {
            SeerrSearchItem(result: $0, badge: SeerrBadge(mediaInfo: $0.mediaInfo, userId: userId))
        }
    }
}

extension SeerrSearchItem {
    /// The poster's pill on Discover, in Seerr web's words: nothing for a
    /// title nobody has asked for.
    var discoverTag: SeerrStatusLabel? {
        switch result.mediaInfo?.mediaStatus {
        case .available: return SeerrStatusLabel(label: "Available", tone: .available)
        case .partiallyAvailable: return SeerrStatusLabel(label: "Partially Available", tone: .coming)
        case .processing: return SeerrStatusLabel(label: "Processing", tone: .coming)
        case .pending: return SeerrStatusLabel(label: "Requested", tone: .pending)
        case .unknown, .blocklisted, .deleted, .none:
            return badge == .declined ? SeerrStatusLabel(label: "Declined", tone: .declined) : nil
        }
    }
}
