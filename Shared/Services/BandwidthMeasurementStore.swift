import Foundation

/// Bandwidth measurements shared by every `JellyfinClient` instance, keyed by
/// server URL (#631).
///
/// The measurement describes the link from this device to a server, not a
/// client object. It used to live on each instance. Only
/// `JellyfinClient.shared` ever probed, but playback runs through its own
/// per-server client (`SessionManager.makeClient`), so the player never saw a
/// measurement. Every Auto stream used the unmeasured default, and on a
/// public hostname that meant 480p. Keying by server also means repointing
/// the shared client and back (server-scoped routes, `restoreActiveClient`)
/// no longer throws the active server's measurement away.
final class BandwidthMeasurementStore: @unchecked Sendable {
    static let shared = BandwidthMeasurementStore()

    struct Measurement: Equatable, Sendable {
        let bitsPerSecond: Int
        let measuredAt: Date
    }

    private let lock = NSLock()
    private var measurements: [String: Measurement] = [:]
    private var probes: [String: Task<Void, Never>] = [:]
    private var skippedOnMeteredNetwork: Set<String> = []

    /// Internal so tests can use an isolated store.
    init() {}

    /// One key per server: scheme, host and port, plus any base path
    /// (a server under a path prefix is still one server). The host is
    /// case-insensitive, and a trailing slash does not change the key.
    static func key(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    func measurement(for url: URL?) -> Measurement? {
        guard let url else { return nil }
        return locked { measurements[Self.key(for: url)] }
    }

    func record(bitsPerSecond: Int, for url: URL, at date: Date = Date()) {
        let measurement = Measurement(bitsPerSecond: bitsPerSecond, measuredAt: date)
        locked { measurements[Self.key(for: url)] = measurement }
    }

    func clearMeasurement(for url: URL) {
        _ = locked { measurements.removeValue(forKey: Self.key(for: url)) }
    }

    /// The most recent probe started for this server, whether it is still
    /// running or has finished. Nil means no probe has run for it in this
    /// process.
    func probe(for url: URL?) -> Task<Void, Never>? {
        guard let url else { return nil }
        return locked { probes[Self.key(for: url)] }
    }

    /// Records a new probe for the server and cancels the one it replaces.
    func replaceProbe(for url: URL, with task: Task<Void, Never>) {
        let previous: Task<Void, Never>? = locked {
            let key = Self.key(for: url)
            let old = probes[key]
            probes[key] = task
            return old
        }
        previous?.cancel()
    }

    func skippedOnMeteredNetwork(for url: URL?) -> Bool {
        guard let url else { return false }
        return locked { skippedOnMeteredNetwork.contains(Self.key(for: url)) }
    }

    func setSkippedOnMeteredNetwork(_ skipped: Bool, for url: URL) {
        let key = Self.key(for: url)
        locked {
            if skipped {
                skippedOnMeteredNetwork.insert(key)
            } else {
                skippedOnMeteredNetwork.remove(key)
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
