import Foundation

/// Titles, posters and media state for TMDB ids, from Seerr's details
/// route. Seerr's request list and Plex watchlist carry only the id (the
/// website fetches each card's details too), so the screens that show them
/// fill in what's missing here, once per title.
@MainActor
final class SeerrTitleCache {
    struct Entry: Equatable {
        let title: String
        let posterPath: String?
        let mediaInfo: SeerrMediaInfo?
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Entry?, Never>] = [:]

    func entry(for target: SeerrTarget) -> Entry? {
        entries[target.id]
    }

    func entry(for request: SeerrRequest) -> Entry? {
        Self.target(for: request).flatMap(entry(for:))
    }

    /// The request's title as a target (title still empty).
    static func target(for request: SeerrRequest) -> SeerrTarget? {
        guard let tmdbId = request.media?.tmdbId, let kind = request.type ?? request.media?.mediaType else { return nil }
        return SeerrTarget(kind: kind, tmdbId: tmdbId, title: "")
    }

    func fill(for requests: [SeerrRequest], client: SeerrClient) async {
        await fill(requests.compactMap(Self.target(for:)), client: client)
    }

    /// Fetches the details of every target not already known, all at once.
    /// A title that fails to load is simply left out.
    func fill(_ targets: [SeerrTarget], client: SeerrClient) async {
        await fill(targets, client: client, maxConcurrent: Int.max)
    }

    /// As `fill(_:client:)`, with at most `maxConcurrent` of this call's requests
    /// open at a time. A title another call is already fetching is joined, not
    /// fetched again: every caller returns only once its titles have resolved.
    func fill(_ targets: [SeerrTarget], client: SeerrClient, maxConcurrent: Int) async {
        let limiter = Limiter(max(1, maxConcurrent))
        var waiting: [Task<Entry?, Never>] = []
        var seen = Set<String>()
        for target in targets {
            let bare = SeerrTarget(kind: target.kind, tmdbId: target.tmdbId, title: "")
            guard entries[bare.id] == nil, seen.insert(bare.id).inserted else { continue }
            if let running = inFlight[bare.id] {
                waiting.append(running)
                continue
            }
            let task = Task { [weak self] () -> Entry? in
                await limiter.acquire()
                let details = try? await client.details(kind: bare.kind, tmdbId: bare.tmdbId)
                await limiter.release()
                let entry = details.map { Entry(title: $0.title, posterPath: $0.posterPath, mediaInfo: $0.mediaInfo) }
                self?.finished(bare.id, entry)
                return entry
            }
            inFlight[bare.id] = task
            waiting.append(task)
        }
        for task in waiting { _ = await task.value }
    }

    private func finished(_ id: String, _ entry: Entry?) {
        inFlight[id] = nil
        if let entry { entries[id] = entry }
    }

    /// Lets at most `limit` holders run at once; the rest wait their turn.
    private actor Limiter {
        private var free: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(_ limit: Int) { free = limit }

        func acquire() async {
            if free > 0 {
                free -= 1
            } else {
                await withCheckedContinuation { waiters.append($0) }
            }
        }

        func release() {
            if waiters.isEmpty {
                free += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
}
