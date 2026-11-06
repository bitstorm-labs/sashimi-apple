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

    /// Fetches the details of every target not already known, in parallel.
    /// A title that fails to load is simply left out.
    func fill(_ targets: [SeerrTarget], client: SeerrClient) async {
        let missing = Set(targets.map { SeerrTarget(kind: $0.kind, tmdbId: $0.tmdbId, title: "") })
            .filter { entries[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let found = await withTaskGroup(of: (String, Entry)?.self) { group in
            for target in missing {
                group.addTask {
                    guard let details = try? await client.details(kind: target.kind, tmdbId: target.tmdbId) else { return nil }
                    return (target.id, Entry(title: details.title, posterPath: details.posterPath, mediaInfo: details.mediaInfo))
                }
            }
            var found: [(String, Entry)] = []
            for await pair in group {
                if let pair { found.append(pair) }
            }
            return found
        }
        for (id, entry) in found {
            entries[id] = entry
        }
    }
}
