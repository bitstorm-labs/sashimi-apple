import Foundation

/// Whether a failed download is worth trying again by itself.
enum DownloadFailureKind: Equatable {
    /// Network trouble, a server hiccup, an interrupted task.
    case transient
    /// Retrying would fail the same way: the item is gone, access is denied,
    /// the device is full, the server isn't set up.
    case permanent
}

/// Failed downloads retry by themselves after 1, 5 and 30 minutes, then stay
/// failed for a manual retry. Only transient failures retry, and only while
/// downloads may use the current network.
enum DownloadRetryPolicy {
    static let delays: [TimeInterval] = [60, 5 * 60, 30 * 60]

    /// The wait before the next automatic retry once a download has failed
    /// `failures` times in a row, or nil when the retries are used up.
    static func delay(afterFailure failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }

    static func classify(httpStatusCode code: Int) -> DownloadFailureKind {
        switch code {
        case 408, 429: return .transient // timeout, rate limited
        case 400..<500: return .permanent // 401/403/404 and friends
        default: return .transient // 5xx and anything unexpected
        }
    }

    static func classify(error: Error) -> DownloadFailureKind {
        if let jellyfin = error as? JellyfinError {
            switch jellyfin {
            case .httpError(let code), .serverMessage(let code, _):
                return classify(httpStatusCode: code)
            case .notConfigured, .invalidCredentials, .sessionExpired, .invalidURL, .nonPlayableItem:
                return .permanent
            case .networkError(let underlying):
                return classify(error: underlying)
            default:
                return .transient
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .permanent
        }
        guard nsError.domain == NSURLErrorDomain else { return .transient }
        switch nsError.code {
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL,
             NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication,
             NSURLErrorNoPermissionsToReadFile, NSURLErrorFileDoesNotExist,
             NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
             NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .permanent
        default:
            return .transient
        }
    }

    /// "Retrying in 5 min" for a scheduled retry; "Will retry on Wi-Fi" when
    /// it is due but the network rules hold it back.
    static func label(nextRetryAt: Date, now: Date, waitReason: DownloadWaitReason?) -> String {
        let remaining = nextRetryAt.timeIntervalSince(now)
        guard remaining > 0 else {
            switch waitReason {
            case .offline: return "Will retry when online"
            case .cellular: return "Will retry on Wi-Fi"
            case .lowDataMode: return "Will retry off Low Data Mode"
            case nil: return "Retrying…"
            }
        }
        let minutes = Int((remaining / 60).rounded(.up))
        return "Retrying in \(minutes) min"
    }
}

/// One download's automatic-retry state, persisted so a relaunch can neither
/// reset the count into an endless loop nor forget a scheduled retry.
struct DownloadRetryEntry: Codable, Equatable {
    let itemId: String
    let serverID: String?
    /// Consecutive transient failures.
    var failures: Int
    /// When the next automatic retry is due; nil once they are used up.
    var nextRetryAt: Date?
}

/// Retry entries keyed by download record ID ("server:item"), stored as one
/// JSON blob in UserDefaults: no SwiftData schema change.
final class DownloadRetryStore {
    static let defaultsKey = "downloadRetryState"

    private let defaults: UserDefaults
    private(set) var entries: [String: DownloadRetryEntry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: DownloadRetryEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    static func key(itemId: String, serverID: String?) -> String {
        "\(serverID ?? "legacy"):\(itemId)"
    }

    func entry(itemId: String, serverID: String?) -> DownloadRetryEntry? {
        entries[Self.key(itemId: itemId, serverID: serverID)]
    }

    /// Counts a failure and schedules the next retry. A permanent failure
    /// clears the entry: it is left for the user to retry.
    @discardableResult
    func recordFailure(
        itemId: String,
        serverID: String?,
        kind: DownloadFailureKind,
        now: Date = Date()
    ) -> DownloadRetryEntry? {
        let key = Self.key(itemId: itemId, serverID: serverID)
        guard kind == .transient else {
            entries.removeValue(forKey: key)
            persist()
            return nil
        }
        let failures = (entries[key]?.failures ?? 0) + 1
        let entry = DownloadRetryEntry(
            itemId: itemId,
            serverID: serverID,
            failures: failures,
            nextRetryAt: DownloadRetryPolicy.delay(afterFailure: failures).map { now.addingTimeInterval($0) }
        )
        entries[key] = entry
        persist()
        return entry
    }

    /// Entries whose retry is due at `now`.
    func due(at now: Date) -> [DownloadRetryEntry] {
        entries.values
            .filter { ($0.nextRetryAt ?? .distantFuture) <= now }
            .sorted { ($0.nextRetryAt ?? .distantFuture) < ($1.nextRetryAt ?? .distantFuture) }
    }

    /// The earliest retry still in the future.
    func nextRetryDate(after now: Date) -> Date? {
        entries.values.compactMap(\.nextRetryAt).filter { $0 > now }.min()
    }

    /// The download finished, was deleted, or the user retried it by hand.
    func clear(itemId: String, serverID: String?) {
        guard entries.removeValue(forKey: Self.key(itemId: itemId, serverID: serverID)) != nil else { return }
        persist()
    }

    func clearAll() {
        entries = [:]
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
