import Foundation

/// The request page (mockup C) for a title that isn't on the server: its
/// details from Seerr, and what the main button does.
@MainActor
final class SeerrDetailModel: ObservableObject {
    enum Action: Equatable {
        case loading
        /// A movie: one press.
        case request
        /// A show: opens the season picker.
        case chooseSeasons
        /// Requested already: "Requested · waiting for approval", "Coming soon"…
        case status(String)
        case failed(String)
    }

    /// Finds the library's copy of a title once it has arrived.
    typealias LibraryLookup = (_ tmdbId: Int, _ kind: SeerrMediaKind, _ title: String) async -> BaseItemDto?

    let target: SeerrTarget
    @Published private(set) var details: SeerrTitleDetails?
    @Published private(set) var action: Action = .loading
    /// Set once the title is on the server: the page becomes the library page.
    @Published private(set) var libraryItem: BaseItemDto?
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    private let session: SeerrSession
    private let libraryLookup: LibraryLookup

    init(
        target: SeerrTarget,
        session: SeerrSession = .shared,
        libraryLookup: @escaping LibraryLookup = SeerrDetailModel.findInLibrary
    ) {
        self.target = target
        self.session = session
        self.libraryLookup = libraryLookup
    }

    var badge: SeerrBadge {
        SeerrBadge(mediaInfo: details?.mediaInfo, userId: session.state.user?.id)
    }

    func load() async {
        guard let client = session.client else {
            action = .failed("Sign in to \(session.applicationTitle) in Settings › Requests.")
            return
        }
        do {
            let details = try await client.details(kind: target.kind, tmdbId: target.tmdbId)
            self.details = details
            action = Self.action(for: details, plan: seasonPlan(for: details), userId: session.state.user?.id)
            if details.mediaInfo?.mediaStatus == .available || details.mediaInfo?.mediaStatus == .partiallyAvailable {
                libraryItem = await libraryLookup(target.tmdbId, target.kind, details.title)
            }
        } catch is CancellationError {
            return
        } catch {
            if details == nil { action = .failed(error.localizedDescription) }
            await session.handle(error)
        }
    }

    func seasonPlan() -> SeerrSeasonPlan? {
        details.flatMap(seasonPlan(for:))
    }

    func requestMovie() async {
        await submit { try await $0.requestMovie(tmdbId: self.target.tmdbId) }
    }

    func requestSeasons(_ plan: SeerrSeasonPlan) async {
        await submit { try await $0.requestShow(tmdbId: self.target.tmdbId, seasons: plan.requestSeasons) }
    }

    private func submit(_ send: @escaping (SeerrClient) async throws -> SeerrRequest) async {
        guard let client = session.client, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await send(client)
            session.requestsChanged()
            await load()
        } catch {
            errorMessage = error.localizedDescription
            await session.handle(error)
        }
    }

    private func seasonPlan(for details: SeerrTitleDetails) -> SeerrSeasonPlan? {
        guard details.kind == .tv else { return nil }
        return SeerrSeasonPlan(details: details, partialRequestsEnabled: session.partialRequestsEnabled)
    }

    static func action(for details: SeerrTitleDetails, plan: SeerrSeasonPlan?, userId: Int?) -> Action {
        if let plan, plan.hasMissingSeasons { return .chooseSeasons }
        switch SeerrBadge(mediaInfo: details.mediaInfo, userId: userId) {
        case .available: return .status("On your server")
        case .coming: return .status("Coming soon")
        case .pending: return .status("Requested · waiting for approval")
        case .request, .declined:
            if let plan {
                return plan.seasons.contains { $0.state.isPickable } ? .chooseSeasons : .status("Every season is on the server or requested")
            }
            return .request
        }
    }

    /// For a library show's More menu: a target when Seerr says some aired
    /// seasons aren't on the server and nobody has asked for them. Nil (and
    /// no request to Seerr) without an account or a TMDB id.
    static func missingSeasonsTarget(for item: BaseItemDto, session: SeerrSession = .shared) async -> SeerrTarget? {
        guard item.type == .series, let tmdbId = item.tmdbId, let client = session.client, session.isActive else { return nil }
        guard let details = try? await client.details(kind: .tv, tmdbId: tmdbId) else { return nil }
        let plan = SeerrSeasonPlan(details: details, partialRequestsEnabled: session.partialRequestsEnabled)
        return plan.hasMissingSeasons ? SeerrTarget(kind: .tv, tmdbId: tmdbId, title: details.title, posterPath: details.posterPath) : nil
    }

    /// The active server's copy of a title, matched by TMDB id among the
    /// library's search results for its name.
    static func findInLibrary(tmdbId: Int, kind: SeerrMediaKind, title: String) async -> BaseItemDto? {
        guard let items = try? await JellyfinClient.shared.search(query: title, limit: 20) else { return nil }
        return SeerrSearchMerge.libraryMatch(in: items, tmdbId: tmdbId, kind: kind)
    }
}

/// "Request Missing Seasons" on a library show's detail page: checks Seerr
/// once per show and holds what the menu item presents.
@MainActor
final class SeerrMissingSeasonsOffer: ObservableObject {
    @Published private(set) var target: SeerrTarget?
    @Published var presented: SeerrTarget?

    func check(_ item: BaseItemDto) async {
        target = await SeerrDetailModel.missingSeasonsTarget(for: item)
    }
}
