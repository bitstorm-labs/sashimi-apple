import Foundation

/// What a request page is opened for.
struct SeerrTarget: Hashable, Identifiable {
    let kind: SeerrMediaKind
    let tmdbId: Int
    let title: String
    var posterPath: String?

    var id: String { "\(kind.rawValue)-\(tmdbId)" }

    init(kind: SeerrMediaKind, tmdbId: Int, title: String, posterPath: String? = nil) {
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.posterPath = posterPath
    }

    init(_ result: SeerrSearchResult) {
        self.init(kind: result.kind, tmdbId: result.tmdbId, title: result.title, posterPath: result.posterPath)
    }
}

struct SeerrSearchItem: Identifiable, Equatable {
    let result: SeerrSearchResult
    let badge: SeerrBadge

    var id: String { result.id }
    var target: SeerrTarget { SeerrTarget(result) }
}

/// Search's "Not in your library" row (mockup B). Silent unless the person
/// has a Seerr account: no account, no row and no request to Seerr.
@MainActor
final class SeerrSearchModel: ObservableObject {
    @Published private(set) var items: [SeerrSearchItem] = []
    private let session: SeerrSession
    /// The Requests page's own search (#845) lists everything Seerr finds,
    /// what's on the server included (it opens the library title); Search's
    /// row leaves those to the library row.
    private let includesAvailable: Bool

    init(session: SeerrSession = .shared, includesAvailable: Bool = false) {
        self.session = session
        self.includesAvailable = includesAvailable
    }

    var isVisible: Bool { session.isActive && !items.isEmpty }

    var sectionTitle: String { "Not in your library · from \(session.applicationTitle)" }

    /// `library` is what the library row is showing for the same query, so
    /// nothing appears in both.
    func search(query: String, library: [BaseItemDto]) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.isActive, let client = session.client, !trimmed.isEmpty else {
            items = []
            return
        }
        do {
            let page = try await client.search(query: trimmed)
            guard !Task.isCancelled else { return }
            let userId = session.state.user?.id
            let results = includesAvailable
                ? SeerrSearchMerge.unique(page.results)
                : SeerrSearchMerge.requestable(page.results, library: library)
            items = results.map {
                SeerrSearchItem(result: $0, badge: SeerrBadge(mediaInfo: $0.mediaInfo, userId: userId))
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            items = []
            await session.handle(error)
        }
    }

    func clear() {
        items = []
    }
}
