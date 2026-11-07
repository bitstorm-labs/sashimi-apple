import Foundation

// The Requests page's shapes (#845), checked against seerr-team/seerr 3.5.1:
// server/lib/permissions.ts, server/routes/request.ts, server/routes/discover.ts
// and server/routes/user/index.ts.

/// Seerr's permission bits (server/lib/permissions.ts). Only the ones the app
/// reads are named.
struct SeerrPermissions: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let admin = SeerrPermissions(rawValue: 2)
    static let manageUsers = SeerrPermissions(rawValue: 8)
    static let manageRequests = SeerrPermissions(rawValue: 16)
    static let request = SeerrPermissions(rawValue: 32)
    static let requestView = SeerrPermissions(rawValue: 16_384)

    /// Seerr's `hasPermission(…, { type: 'or' })`: an administrator has
    /// every permission; anyone else needs one of `any`.
    func allows(any: SeerrPermissions) -> Bool {
        contains(.admin) || !intersection(any).isEmpty
    }

    /// `GET /request` without `requestedBy` lists everyone's requests only
    /// for MANAGE_REQUESTS or REQUEST_VIEW (anyone else gets their own, and a
    /// 403 when asking for someone else's).
    var canViewAllRequests: Bool { allows(any: [.manageRequests, .requestView]) }

    /// Approve, decline (`isAuthenticated(MANAGE_REQUESTS)`) and delete any
    /// request, not just one's own pending one.
    var canManageRequests: Bool { allows(any: .manageRequests) }
}

extension SeerrUser {
    var permissionSet: SeerrPermissions { SeerrPermissions(rawValue: permissions ?? 0) }
}

/// The filter on `GET /request` (`filter=`), as the server reads it. Seerr
/// has no filter for declined requests; they only appear under All.
enum SeerrRequestFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pending
    case approved
    case processing
    case available
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .processing: return "Processing"
        case .available: return "Available"
        case .failed: return "Failed"
        }
    }
}

/// Whose requests the list shows.
/// Everyone comes first: the list opens on all requests for those who may
/// see them (#855); anyone else only ever gets their own.
enum SeerrRequestScope: String, CaseIterable, Identifiable, Sendable {
    case everyone
    case mine

    var id: String { rawValue }
    var title: String { self == .mine ? "Mine" : "Everyone" }
}

/// `GET /request/count`: every request on the server, whoever asked.
struct SeerrRequestCount: Decodable, Equatable, Sendable {
    var total: Int?
    var movie: Int?
    var tv: Int?
    var pending: Int?
    var approved: Int?
    var declined: Int?
    var processing: Int?
    var available: Int?
    var completed: Int?

    /// "493 requests · 0 pending · 78 processing · 56 available".
    var summary: String {
        var parts = ["\(total ?? 0) requests"]
        parts.append("\(pending ?? 0) pending")
        if let processing { parts.append("\(processing) processing") }
        if let available { parts.append("\(available) available") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// One half of `GET /user/{id}/quota`. A `limit` of 0 (or none) is unlimited;
/// TV quotas count seasons.
struct SeerrQuotaStatus: Decodable, Equatable, Sendable {
    var days: Int?
    var limit: Int?
    var used: Int?
    var remaining: Int?
    var restricted: Bool?  // swiftlint:disable:this discouraged_optional_boolean
}

struct SeerrQuota: Decodable, Equatable, Sendable {
    var movie: SeerrQuotaStatus?
    var tv: SeerrQuotaStatus?

    /// The line under the Request button: nil without a limit.
    /// "2 of 5 movie requests left · resets over 7 days".
    func summary(for kind: SeerrMediaKind) -> String? {
        guard let status = kind == .movie ? movie : tv, let limit = status.limit, limit > 0 else { return nil }
        let noun = kind == .movie ? "movie" : "season"
        let left = max(0, status.remaining ?? (limit - (status.used ?? 0)))
        let window = status.days.map { $0 > 0 ? " \u{00B7} resets over \($0) day\($0 == 1 ? "" : "s")" : "" } ?? ""
        if status.restricted == true || left == 0 {
            return "You've used all \(limit) of your \(noun) requests\(window)"
        }
        return "\(left) of \(limit) \(noun) requests left\(window)"
    }
}

/// The Discover page's rows, in Seerr web's order (src/components/Discover).
enum SeerrDiscoverSlider: String, CaseIterable, Identifiable, Sendable {
    case recentRequests
    case trending
    case popularMovies
    case upcomingMovies
    case popularSeries
    case upcomingSeries
    /// The Plex Watchlist; empty (and hidden) for local accounts without one.
    case watchlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentRequests: return "Recent Requests"
        case .trending: return "Trending"
        case .popularMovies: return "Popular Movies"
        case .upcomingMovies: return "Upcoming Movies"
        case .popularSeries: return "Popular Series"
        case .upcomingSeries: return "Upcoming Series"
        case .watchlist: return "Your Watchlist"
        }
    }

    /// The `/api/v1/` path; nil for Recent Requests, which is `GET /request`.
    var path: String? {
        switch self {
        case .recentRequests: return nil
        case .trending: return "discover/trending"
        case .popularMovies: return "discover/movies"
        case .upcomingMovies: return "discover/movies/upcoming"
        case .popularSeries: return "discover/tv"
        case .upcomingSeries: return "discover/tv/upcoming"
        case .watchlist: return "discover/watchlist"
        }
    }
}
