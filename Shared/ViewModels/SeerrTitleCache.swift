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
    private var inFlight = Set<String>()

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

    /// As `fill(_:client:)`, with at most `maxConcurrent` requests open at a time.
    /// A title already being fetched by another call isn't fetched again.
    func fill(_ targets: [SeerrTarget], client: SeerrClient, maxConcurrent: Int) async {
        var seen = Set<String>()
        var queue = targets
            .map { SeerrTarget(kind: $0.kind, tmdbId: $0.tmdbId, title: "") }
            .filter { entries[$0.id] == nil && !inFlight.contains($0.id) && seen.insert($0.id).inserted }
        guard !queue.isEmpty else { return }
        inFlight.formUnion(queue.map(\.id))
        let limit = max(1, maxConcurrent)
        await withTaskGroup(of: (SeerrTarget, Entry?).self) { group in
            func startNext() {
                guard !queue.isEmpty else { return }
                let target = queue.removeFirst()
                group.addTask {
                    guard let details = try? await client.details(kind: target.kind, tmdbId: target.tmdbId) else { return (target, nil) }
                    return (target, Entry(title: details.title, posterPath: details.posterPath, mediaInfo: details.mediaInfo))
                }
            }
            for _ in 0..<min(limit, queue.count) { startNext() }
            for await (target, entry) in group {
                inFlight.remove(target.id)
                if let entry { entries[target.id] = entry }
                startNext()
            }
        }
    }
}
