import Foundation

/// A status word and the colour family it takes (`SeerrBadge.color`).
struct SeerrStatusLabel: Equatable, Sendable {
    let label: String
    let tone: SeerrBadge
}

/// What the person may do to one request in the list.
enum SeerrRequestAction: String, Identifiable, Sendable {
    case approve
    case decline
    /// The requester's own pending request.
    case cancel
    /// MANAGE_REQUESTS: any request, whoever made it.
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approve: return "Approve"
        case .decline: return "Decline"
        case .cancel: return "Cancel Request"
        case .delete: return "Delete Request"
        }
    }

    var systemImage: String {
        switch self {
        case .approve: return "checkmark.circle"
        case .decline, .cancel: return "xmark.circle"
        case .delete: return "trash"
        }
    }

    var isDestructive: Bool { self != .approve }
}

extension SeerrRequestRow {
    /// Who asked: their Seerr display name.
    var requesterName: String { request.requestedBy?.name ?? "Unknown" }

    /// "Movie", "Series · S1–3".
    var kindLabel: String {
        guard kind == .tv else { return "Movie" }
        let seasons = (request.seasons ?? []).map(\.seasonNumber).sorted()
        guard let first = seasons.first, let last = seasons.last else { return "Series" }
        if seasons.count == 1 { return "Series \u{00B7} S\(first)" }
        if last - first + 1 == seasons.count { return "Series \u{00B7} S\(first)\u{2013}\(last)" }
        return "Series \u{00B7} \(seasons.count) seasons"
    }

    /// The request's own state, as Seerr's request list words it.
    var requestStatus: SeerrStatusLabel {
        switch request.requestStatus {
        case .pending: return SeerrStatusLabel(label: "Pending", tone: .pending)
        case .approved: return SeerrStatusLabel(label: "Approved", tone: .coming)
        case .declined: return SeerrStatusLabel(label: "Declined", tone: .declined)
        case .failed: return SeerrStatusLabel(label: "Failed", tone: .declined)
        case .completed: return SeerrStatusLabel(label: "Completed", tone: .available)
        case .none: return SeerrStatusLabel(label: "Unknown", tone: .request)
        }
    }

    /// Where the title itself stands; nil when that adds nothing (nobody
    /// has it yet, or it's waiting on this same request).
    var mediaStatus: SeerrStatusLabel? {
        switch request.media?.mediaStatus {
        case .available: return SeerrStatusLabel(label: "Available", tone: .available)
        case .partiallyAvailable: return SeerrStatusLabel(label: "Partially Available", tone: .coming)
        case .processing: return SeerrStatusLabel(label: "Processing", tone: .coming)
        case .deleted: return SeerrStatusLabel(label: "Deleted", tone: .declined)
        case .blocklisted: return SeerrStatusLabel(label: "Blocklisted", tone: .declined)
        case .pending, .unknown, .none: return nil
        }
    }

    /// Download progress (0…1) when Radarr/Sonarr report one.
    var progress: Double? { SeerrRequestState.progress(request.media) }

    /// "Requested Tue" / "Requested Nov 2".
    func requestedLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = SeerrDates.parse(request.createdAt) else { return "Requested" }
        return "Requested \(SeerrRequestState.dayLabel(date, now: now, calendar: calendar))"
    }
}

/// The Requests section of the Requests page (#845), like Seerr web's
/// /requests: one filter, newest first, the person's own or (with
/// MANAGE_REQUESTS or REQUEST_VIEW) everyone's, loaded a page at a time.
/// Approve, decline and delete appear only for permissions that allow them;
/// the server enforces the same rules.
@MainActor
final class SeerrRequestListModel: ObservableObject {
    @Published var filter: SeerrRequestFilter = .all
    @Published var scope: SeerrRequestScope = .mine
    @Published private(set) var rows: [SeerrRequestRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var canLoadMore = false
    /// Everyone's requests by state; only for those who may see everyone's.
    @Published private(set) var count: SeerrRequestCount?
    /// Requests with an action in flight, so their buttons can wait.
    @Published private(set) var busy: Set<Int> = []
    @Published var errorMessage: String?

    let pageSize: Int
    private let session: SeerrSession
    private let titles = SeerrTitleCache()
    /// Requests fetched so far (rows can be fewer: some name no title).
    private var fetched = 0
    private var generation = 0

    init(session: SeerrSession = .shared, pageSize: Int = 20) {
        self.session = session
        self.pageSize = pageSize
    }

    var permissions: SeerrPermissions { session.permissions }

    /// The Mine / Everyone switch; hidden for anyone who can only see
    /// their own requests.
    var canChooseScope: Bool { permissions.canViewAllRequests }

    /// The scope actually asked for.
    var effectiveScope: SeerrRequestScope { canChooseScope ? scope : .mine }

    /// Whether the requester's name is worth showing on each row.
    var showsRequester: Bool { effectiveScope == .everyone }

    /// From the first page again, for the current filter and scope.
    func reload() async {
        generation += 1
        fetched = 0
        canLoadMore = false
        await loadPage(replacing: true)
        if canChooseScope, let client = session.client {
            count = try? await client.requestCount()
        } else {
            count = nil
        }
    }

    /// Paging: call as each row appears; the next page loads near the end.
    func loadMoreIfNeeded(after row: SeerrRequestRow) async {
        guard canLoadMore, !isLoading,
              let index = rows.firstIndex(where: { $0.id == row.id }),
              index >= rows.count - 5 else { return }
        await loadPage(replacing: false)
    }

    func actions(for row: SeerrRequestRow) -> [SeerrRequestAction] {
        let isPending = row.request.requestStatus == .pending
        if permissions.canManageRequests {
            return (isPending ? [.approve, .decline] : []) + [.delete]
        }
        let isMine = row.request.requestedBy?.id == session.state.user?.id
        return isMine && isPending ? [.cancel] : []
    }

    /// Runs one action. Nothing is sent for an action the person lacks.
    func perform(_ action: SeerrRequestAction, on row: SeerrRequestRow) async {
        guard actions(for: row).contains(action), let client = session.client, !busy.contains(row.id) else { return }
        busy.insert(row.id)
        errorMessage = nil
        defer { busy.remove(row.id) }
        do {
            switch action {
            case .approve:
                _ = try await client.approveRequest(id: row.id)
                update(row, status: .approved)
            case .decline:
                _ = try await client.declineRequest(id: row.id)
                update(row, status: .declined)
            case .cancel, .delete:
                try await client.cancelRequest(id: row.id)
                rows.removeAll { $0.id == row.id }
            }
            session.requestsChanged()
        } catch {
            errorMessage = error.localizedDescription
            await session.handle(error)
        }
    }

    // MARK: Private

    private func loadPage(replacing: Bool) async {
        guard let client = session.client, let user = session.state.user else {
            rows = []
            hasLoaded = true
            return
        }
        let generation = generation
        let requestedBy = effectiveScope == .mine ? user.id : nil
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let page = try await client.requestPage(filter: filter, take: pageSize, skip: fetched, requestedBy: requestedBy)
            await titles.fill(for: page.results, client: client)
            guard !Task.isCancelled, generation == self.generation else { return }
            let now = Date()
            let newRows = page.results.compactMap { SeerrRequestRow($0, titles: titles, now: now) }
            if replacing {
                rows = newRows
            } else {
                let known = Set(rows.map(\.id))
                rows += newRows.filter { !known.contains($0.id) }
            }
            fetched += page.results.count
            if let total = page.pageInfo?.results {
                canLoadMore = fetched < total
            } else {
                canLoadMore = page.results.count == pageSize
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            if replacing { rows = [] }
            canLoadMore = false
            errorMessage = error.localizedDescription
            await session.handle(error)
        }
    }

    /// The new state locally until the reload lands; a row the filter no
    /// longer matches leaves.
    private func update(_ row: SeerrRequestRow, status: SeerrRequestStatus) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        if filter == .pending {
            rows.remove(at: index)
            return
        }
        let request = SeerrRequest(
            id: row.request.id,
            status: status.rawValue,
            type: row.request.type,
            createdAt: row.request.createdAt,
            updatedAt: row.request.updatedAt,
            seasons: row.request.seasons,
            media: row.request.media,
            requestedBy: row.request.requestedBy,
            modifiedBy: row.request.modifiedBy
        )
        rows[index] = SeerrRequestRow(
            id: row.id,
            request: request,
            kind: row.kind,
            tmdbId: row.tmdbId,
            title: row.title,
            posterPath: row.posterPath,
            state: SeerrRequestState(request),
            subtitle: SeerrRequestState.subtitle(for: request)
        )
    }
}
