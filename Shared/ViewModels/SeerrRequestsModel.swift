import Foundation

/// One of the person's requests, with the title Seerr's request list leaves
/// out (it only carries the TMDB id).
struct SeerrRequestRow: Identifiable, Equatable {
    let id: Int
    let request: SeerrRequest
    let kind: SeerrMediaKind
    let tmdbId: Int
    let title: String
    let posterPath: String?
    let state: SeerrRequestState
    let subtitle: String

    /// Nil when the request names no title (Seerr can return one whose media
    /// row is gone).
    @MainActor
    init?(_ request: SeerrRequest, titles: SeerrTitleCache, now: Date = Date()) {
        guard let target = SeerrTitleCache.target(for: request) else { return nil }
        let known = titles.entry(for: target)
        self.init(
            id: request.id,
            request: request,
            kind: target.kind,
            tmdbId: target.tmdbId,
            title: known?.title ?? "Unknown title",
            posterPath: known?.posterPath,
            state: SeerrRequestState(request),
            subtitle: SeerrRequestState.subtitle(for: request, now: now)
        )
    }

    init(
        id: Int,
        request: SeerrRequest,
        kind: SeerrMediaKind,
        tmdbId: Int,
        title: String,
        posterPath: String?,
        state: SeerrRequestState,
        subtitle: String
    ) {
        self.id = id
        self.request = request
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.posterPath = posterPath
        self.state = state
        self.subtitle = subtitle
    }

    var target: SeerrTarget { SeerrTarget(kind: kind, tmdbId: tmdbId, title: title, posterPath: posterPath) }

    /// "Dune: Prophecy · S1" for a show request.
    var displayTitle: String {
        guard kind == .tv, let seasons = request.seasons?.map(\.seasonNumber).sorted(), !seasons.isEmpty else {
            return title
        }
        if seasons.count == 1 { return "\(title) · S\(seasons[0])" }
        if let first = seasons.first, let last = seasons.last, last - first + 1 == seasons.count {
            return "\(title) · S\(first)–\(last)"
        }
        return "\(title) · \(seasons.count) seasons"
    }
}

/// The person's own requests for Home's "Your Requests" row (mockup E). The
/// Requests page's full list is `SeerrRequestListModel` (#845).
@MainActor
final class SeerrRequestsModel: ObservableObject {
    @Published private(set) var rows: [SeerrRequestRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    private let session: SeerrSession
    private let titles = SeerrTitleCache()

    init(session: SeerrSession = .shared) {
        self.session = session
    }

    /// Only while something waits or arrived in the last week.
    var homeRows: [SeerrRequestRow] {
        rows.filter { SeerrRequestState.showsOnHome($0.request) }
    }

    func load() async {
        guard session.isActive, let client = session.client, let user = session.state.user else {
            rows = []
            return
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let requests = try await client.requests(requestedBy: user.id)
            await titles.fill(for: requests, client: client)
            guard !Task.isCancelled else { return }
            let now = Date()
            rows = requests.compactMap { SeerrRequestRow($0, titles: titles, now: now) }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            await session.handle(error)
        }
    }
}
