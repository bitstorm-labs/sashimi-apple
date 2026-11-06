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

    var canCancel: Bool { state == .pending }

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

/// Your requests (mockup E) and the Home row built from them.
@MainActor
final class SeerrRequestsModel: ObservableObject {
    @Published private(set) var rows: [SeerrRequestRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    private let session: SeerrSession
    private var titles: [String: (title: String, poster: String?)] = [:]

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
            await fillTitles(for: requests, client: client)
            guard !Task.isCancelled else { return }
            let now = Date()
            rows = requests.compactMap { request in
                guard let tmdbId = request.media?.tmdbId,
                      let kind = request.type ?? request.media?.mediaType else { return nil }
                let known = titles["\(kind.rawValue)-\(tmdbId)"]
                return SeerrRequestRow(
                    id: request.id,
                    request: request,
                    kind: kind,
                    tmdbId: tmdbId,
                    title: known?.title ?? "Unknown title",
                    posterPath: known?.poster,
                    state: SeerrRequestState(request),
                    subtitle: SeerrRequestState.subtitle(for: request, now: now)
                )
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            await session.handle(error)
        }
    }

    /// Pending requests only; Seerr refuses the rest.
    func cancel(_ row: SeerrRequestRow) async {
        guard row.canCancel, let client = session.client else { return }
        do {
            try await client.cancelRequest(id: row.id)
            rows.removeAll { $0.id == row.id }
            session.requestsChanged()
        } catch {
            errorMessage = error.localizedDescription
            await session.handle(error)
        }
    }

    private func fillTitles(for requests: [SeerrRequest], client: SeerrClient) async {
        let missing = Set(requests.compactMap { request -> SeerrTarget? in
            guard let tmdbId = request.media?.tmdbId, let kind = request.type ?? request.media?.mediaType else { return nil }
            return SeerrTarget(kind: kind, tmdbId: tmdbId, title: "")
        }).filter { titles[$0.id] == nil }

        let found = await withTaskGroup(of: SeerrTarget?.self) { group in
            for target in missing {
                group.addTask {
                    guard let details = try? await client.details(kind: target.kind, tmdbId: target.tmdbId) else { return nil }
                    return SeerrTarget(kind: target.kind, tmdbId: target.tmdbId, title: details.title, posterPath: details.posterPath)
                }
            }
            var found: [SeerrTarget] = []
            for await entry in group {
                if let entry { found.append(entry) }
            }
            return found
        }
        for target in found {
            titles[target.id] = (target.title, target.posterPath)
        }
    }
}
