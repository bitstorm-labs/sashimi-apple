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

    // MARK: Sustained throughput (what playback itself achieved)

    /// Access-log readings kept per server and link kind. Few, recent: a link
    /// that changes (a new router, a move to another room) should not be
    /// judged by last month.
    static let sustainedSampleLimit = 5
    /// A reading counts only after this much video: the first segments of a
    /// stream arrive in a burst that says little about the link.
    static let sustainedMinimumBytes: Int64 = 16_000_000
    static let sustainedDefaultsKey = "playback.sustainedThroughput"

    private let defaults: UserDefaults

    private static func sustainedKey(for url: URL, isWired: Bool) -> String {
        key(for: url) + (isWired ? "|wired" : "|wireless")
    }

    /// Records one access-log reading (AVPlayerItemAccessLogEvent's
    /// observedBitrate over `bytesTransferred`). Kept across launches.
    func recordSustained(bitsPerSecond: Double, bytesTransferred: Int64, for url: URL, isWired: Bool) {
        guard Self.isUsableSustainedReading(bitsPerSecond: bitsPerSecond, bytesTransferred: bytesTransferred) else { return }
        let key = Self.sustainedKey(for: url, isWired: isWired)
        locked {
            var all = defaults.dictionary(forKey: Self.sustainedDefaultsKey) as? [String: [Int]] ?? [:]
            all[key] = Self.addingSustainedSample(
                to: all[key] ?? [], bitsPerSecond: bitsPerSecond, bytesTransferred: bytesTransferred
            )
            defaults.set(all, forKey: Self.sustainedDefaultsKey)
        }
    }

    /// `samples` with one more reading, newest last, at most
    /// `sustainedSampleLimit` of them. A reading over too little video is
    /// dropped. Shared by the remembered samples and a player's per-item ones.
    static func addingSustainedSample(to samples: [Int], bitsPerSecond: Double, bytesTransferred: Int64) -> [Int] {
        guard isUsableSustainedReading(bitsPerSecond: bitsPerSecond, bytesTransferred: bytesTransferred) else { return samples }
        return Array((samples + [Int(bitsPerSecond)]).suffix(sustainedSampleLimit))
    }

    private static func isUsableSustainedReading(bitsPerSecond: Double, bytesTransferred: Int64) -> Bool {
        bitsPerSecond.isFinite && bitsPerSecond > 0 && bytesTransferred >= sustainedMinimumBytes
    }

    /// The lowest recent reading for this server over this kind of link, or
    /// nil when there is none. The lowest, not the average: one slow stretch
    /// (a stall) is the evidence that matters.
    func sustainedBitrate(for url: URL?, isWired: Bool) -> Int? {
        guard let url else { return nil }
        let key = Self.sustainedKey(for: url, isWired: isWired)
        return locked {
            (defaults.dictionary(forKey: Self.sustainedDefaultsKey) as? [String: [Int]])?[key]?.min()
        }
    }

    private let lock = NSLock()
    private var measurements: [String: Measurement] = [:]
    private var probes: [String: Task<Void, Never>] = [:]
    private var skippedOnMeteredNetwork: Set<String> = []

    /// Internal so tests can use an isolated store.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
