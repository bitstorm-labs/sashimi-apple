import Foundation

/// The pill on a "Not in your library" poster (mockup B), and the request
/// page's state before anyone presses anything.
enum SeerrBadge: Equatable, Sendable {
    /// Nobody has asked for it, or only some seasons are on the server.
    case request
    /// Asked for, waiting for approval.
    case pending
    /// Approved and on its way.
    case coming
    /// The person's own request was turned down.
    case declined
    /// On the server. Search never shows these; the library row does.
    case available

    /// `userId` is the signed-in person: only their own declined request
    /// reads "Declined" — someone else's doesn't stop them asking.
    init(mediaInfo: SeerrMediaInfo?, userId: Int?) {
        switch mediaInfo?.mediaStatus {
        case .available:
            self = .available
        case .processing:
            self = .coming
        case .pending:
            self = .pending
        case .partiallyAvailable:
            self = .request
        case .unknown, .blocklisted, .deleted, .none:
            let mine = (mediaInfo?.requests ?? []).filter { userId == nil || $0.requestedBy?.id == userId }
            let latest = mine.max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            self = latest?.requestStatus == .declined ? .declined : .request
        }
    }

    var label: String {
        switch self {
        case .request: return "Request"
        case .pending: return "Pending"
        case .coming: return "Coming"
        case .declined: return "Declined"
        case .available: return "On server"
        }
    }
}

/// Where one of the person's requests stands (mockup E).
enum SeerrRequestState: Equatable, Sendable {
    case pending
    /// Approved and downloading. `progress` (0…1) when Radarr/Sonarr report
    /// a download.
    case coming(progress: Double?)
    /// On the server: opens the library title.
    case ready
    case declined
    /// Approved but sending it to Radarr/Sonarr failed.
    case failed

    init(_ request: SeerrRequest) {
        switch request.requestStatus {
        case .declined:
            self = .declined
        case .pending:
            self = .pending
        case .failed:
            self = Self.isOnServer(request) ? .ready : .failed
        case .approved, .completed, .none:
            self = Self.isOnServer(request) ? .ready : .coming(progress: Self.progress(request.media))
        }
    }

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .coming: return "Coming"
        case .ready: return "Ready"
        case .declined: return "Declined"
        case .failed: return "Failed"
        }
    }

    /// A movie is ready when it's on the server; a show when every season
    /// this request asked for is.
    private static func isOnServer(_ request: SeerrRequest) -> Bool {
        guard let media = request.media else { return false }
        if media.mediaStatus == .available { return true }
        guard request.type == .tv, media.mediaStatus == .partiallyAvailable,
              let asked = request.seasons?.map(\.seasonNumber), !asked.isEmpty else { return false }
        let onServer = Set((media.seasons ?? []).filter { $0.status == SeerrMediaStatus.available.rawValue }.map(\.seasonNumber))
        return asked.allSatisfy(onServer.contains)
    }

    static func progress(_ media: SeerrMediaInfo?) -> Double? {
        let downloads = (media?.downloadStatus ?? []).filter { ($0.size ?? 0) > 0 }
        guard !downloads.isEmpty else { return nil }
        let size = downloads.reduce(0) { $0 + ($1.size ?? 0) }
        let left = downloads.reduce(0) { $0 + min($1.sizeLeft ?? 0, $1.size ?? 0) }
        return max(0, min(1, (size - left) / size))
    }

    /// When the title landed on the server.
    static func arrival(_ request: SeerrRequest) -> Date? {
        SeerrDates.parse(request.media?.mediaAddedAt) ?? SeerrDates.parse(request.media?.updatedAt)
    }

    /// "Requested today", "Approved Tue · 62% downloaded", "Arrived yesterday".
    static func subtitle(for request: SeerrRequest, now: Date = Date(), calendar: Calendar = .current) -> String {
        let state = SeerrRequestState(request)
        switch state {
        case .pending:
            return dated("Requested", SeerrDates.parse(request.createdAt), now: now, calendar: calendar)
        case .coming(let progress):
            let approved = dated("Approved", SeerrDates.parse(request.updatedAt), now: now, calendar: calendar)
            guard let progress else { return approved }
            return "\(approved) · \(Int((progress * 100).rounded()))% downloaded"
        case .ready:
            return dated("Arrived", arrival(request), now: now, calendar: calendar)
        case .declined:
            return "Declined"
        case .failed:
            return "Approved, but it couldn't be sent for download"
        }
    }

    /// The Home row (mockup E): while something waits, or for a week after
    /// it arrives. Declined and failed requests stay in Your requests.
    static func showsOnHome(_ request: SeerrRequest, now: Date = Date()) -> Bool {
        switch SeerrRequestState(request) {
        case .pending, .coming:
            return true
        case .ready:
            guard let arrival = arrival(request) else { return false }
            return now.timeIntervalSince(arrival) < 7 * 24 * 60 * 60
        case .declined, .failed:
            return false
        }
    }

    private static func dated(_ verb: String, _ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return verb }
        return "\(verb) \(dayLabel(date, now: now, calendar: calendar))"
    }

    /// "today", "yesterday", a weekday within the week, else "Nov 2".
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<7:
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        default:
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}
