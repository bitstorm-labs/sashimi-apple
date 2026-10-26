import Foundation

/// "Remove from Continue Watching" (#742). The contract is shared with the
/// Android and Roku clients and the Continue Watching plugin:
///
/// 1. An item with a resume position has it cleared on the server (watched
///    state is untouched), so it leaves Resume everywhere.
/// 2. An episode also hides its series from Next Up — in the plugin when the
///    server has it, otherwise in `ContinueWatchingHideStore` on this device.
/// 3. A hidden series stays hidden only while its Next Up episode is still the
///    one that was hidden. When the row offers a different episode of it, the
///    entry is stale and the series comes back. Playing any episode of the
///    series on this device also brings it back.
enum ContinueWatchingRemoval {
    /// What removing one card does.
    struct Plan: Equatable {
        /// The resume position to clear, and to put back on Undo. Nil when the
        /// item has none.
        let resumeTicks: Int64?
        /// The series to hide from Next Up. Nil for anything that isn't an
        /// episode of a series.
        let hide: HiddenContinueWatchingEntry.Key?

        var clearsResume: Bool { resumeTicks != nil }
    }

    static func plan(for item: BaseItemDto) -> Plan {
        let ticks = item.userData?.playbackPositionTicks ?? 0
        var hide: HiddenContinueWatchingEntry.Key?
        if item.type == .episode, let seriesId = item.seriesId, !seriesId.isEmpty {
            hide = .init(seriesId: seriesId, episodeId: item.id)
        }
        return Plan(resumeTicks: ticks > 0 ? ticks : nil, hide: hide)
    }

    /// The row with hidden series taken out, and the entries that are still in
    /// force (stale ones dropped).
    ///
    /// An entry whose series is not in the row at all is kept: nothing says its
    /// Next Up has moved on (the plugin leaves hidden series out of its row).
    static func filter(
        _ row: [BaseItemDto],
        hidden: [HiddenContinueWatchingEntry]
    ) -> (row: [BaseItemDto], live: [HiddenContinueWatchingEntry]) {
        guard !hidden.isEmpty else { return (row, hidden) }

        var live: [HiddenContinueWatchingEntry] = []
        var hiddenSeries = Set<String>()
        for entry in hidden {
            let offered = row.filter { $0.seriesId == entry.seriesId }
            if offered.isEmpty || offered.contains(where: { $0.id == entry.episodeId }) {
                live.append(entry)
                if !offered.isEmpty { hiddenSeries.insert(entry.seriesId) }
            }
        }
        let visible = row.filter { item in
            guard let seriesId = item.seriesId else { return true }
            return !hiddenSeries.contains(seriesId)
        }
        return (visible, live)
    }
}

/// One series hidden from Continue Watching on this device.
struct HiddenContinueWatchingEntry: Codable, Equatable {
    struct Key: Equatable {
        let seriesId: String
        let episodeId: String
    }

    let seriesId: String
    let episodeId: String
    let hiddenAt: Date
    /// The plugin stored it too, so bringing the series back must tell the
    /// server as well.
    var isOnServer: Bool
}

/// Hidden series per server and user, in UserDefaults. Used when the server has
/// no Continue Watching plugin (or an older one without the hide endpoint), and
/// as a mirror of plugin hides so playback on this device can lift them.
@MainActor
final class ContinueWatchingHideStore {
    static let shared = ContinueWatchingHideStore()

    /// Same cap as the plugin's.
    static let maxEntries = 500
    private static let keyPrefix = "continueWatchingHidden."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The per-server, per-user scope, or nil when not signed in.
    nonisolated static func scope(serverURL: URL?, userId: String?) -> String? {
        guard let serverURL, let userId, !userId.isEmpty else { return nil }
        var host = serverURL.absoluteString
        while host.hasSuffix("/") { host.removeLast() }
        return "\(host)|\(userId)"
    }

    func entries(scope: String) -> [HiddenContinueWatchingEntry] {
        guard let data = defaults.data(forKey: Self.keyPrefix + scope),
              let entries = try? JSONDecoder().decode([HiddenContinueWatchingEntry].self, from: data) else { return [] }
        return entries
    }

    func replace(_ entries: [HiddenContinueWatchingEntry], scope: String) {
        let key = Self.keyPrefix + scope
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        // Newest last; the oldest go first past the cap.
        let capped = Array(entries.suffix(Self.maxEntries))
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: key)
        }
    }

    /// Hide a series. A newer hide of the same series replaces the old one.
    func add(_ entry: HiddenContinueWatchingEntry, scope: String) {
        var current = entries(scope: scope).filter { $0.seriesId != entry.seriesId }
        current.append(entry)
        replace(current, scope: scope)
    }

    func remove(episodeId: String, scope: String) {
        replace(entries(scope: scope).filter { $0.episodeId != episodeId }, scope: scope)
    }

    /// Bring a series back, returning what was removed.
    @discardableResult
    func removeSeries(_ seriesId: String, scope: String) -> [HiddenContinueWatchingEntry] {
        let current = entries(scope: scope)
        let removed = current.filter { $0.seriesId == seriesId }
        guard !removed.isEmpty else { return [] }
        replace(current.filter { $0.seriesId != seriesId }, scope: scope)
        return removed
    }
}

extension ContinueWatchingHideStore {
    /// Playing any episode of a hidden series on this device brings it back,
    /// on the server too when the plugin holds the hide.
    func playbackStarted(of item: BaseItemDto, client: JellyfinClient) async {
        guard let seriesId = item.seriesId,
              let scope = Self.scope(serverURL: await client.currentServerURL, userId: await client.currentUserId)
        else { return }
        for entry in removeSeries(seriesId, scope: scope) where entry.isOnServer {
            try? await client.unhideFromContinueWatching(episodeId: entry.episodeId)
        }
    }
}

/// What one removal did, so Undo can reverse exactly that.
struct ContinueWatchingRemovalReceipt: Equatable {
    let item: BaseItemDto
    /// What was actually done: `resumeTicks` is nil when clearing failed.
    let plan: ContinueWatchingRemoval.Plan
    var hiddenEntry: HiddenContinueWatchingEntry?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id && lhs.plan == rhs.plan && lhs.hiddenEntry == rhs.hiddenEntry
    }
}

/// The confirmation the Home screen shows after a removal.
enum ContinueWatchingRemovalNotice: Equatable {
    case removed(ContinueWatchingRemovalReceipt)
    case failed(BaseItemDto)

    var receipt: ContinueWatchingRemovalReceipt? {
        if case .removed(let receipt) = self { return receipt }
        return nil
    }

    var message: String {
        switch self {
        case .removed: return "Removed from Continue Watching"
        case .failed: return "Couldn't remove from Continue Watching"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.removed(let left), .removed(let right)): return left == right
        case (.failed(let left), .failed(let right)): return left.id == right.id
        default: return false
        }
    }
}

extension ContinueWatchingRemoval {
    /// The card that should take focus when `removedId` leaves the row: the
    /// one after it, or the one before when it was last. Nil when the row is
    /// left empty.
    static func focusAfterRemoving(_ removedId: String, from ids: [String]) -> String? {
        guard let index = ids.firstIndex(of: removedId) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}
