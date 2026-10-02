import Foundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "DownloadWatchState")

/// The server's watched/progress state and community rating for downloaded
/// items, fetched in one batch per server and cached in UserDefaults so the
/// Downloads screen keeps its marks offline. Kept out of the SwiftData download model on purpose:
/// it is a disposable cache, and the store needs no schema change.
@MainActor
final class DownloadWatchStateStore: ObservableObject {
    static let shared = DownloadWatchStateStore()

    /// Item reference handed in by the view: plain values, not the model.
    struct ItemRef: Hashable {
        let recordID: String
        let itemID: String
        let serverID: String?
    }

    private static let defaultsKey = "downloadWatchStateCache"
    /// Jellyfin accepts long `Ids` lists, but URLs have practical limits.
    private static let batchSize = 80

    @Published private(set) var serverStates: [String: ServerWatchState]
    private var isRefreshing = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ServerWatchState].self, from: data) {
            serverStates = decoded
        } else {
            serverStates = [:]
        }
    }

    /// Pushes offline progress first (so the server answer includes it), then
    /// fetches the current UserData for every downloaded item. Failures leave
    /// the cached state in place.
    func refresh(_ items: [ItemRef]) async {
        guard !isRefreshing, !items.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await DownloadManager.shared.syncPendingProgress()

        let activeServerID = SessionManager.shared.activeServerId
        let byServer = Dictionary(grouping: items) { $0.serverID ?? activeServerID ?? "" }
        var updated = serverStates
        for (serverID, refs) in byServer where !serverID.isEmpty {
            guard let client = SessionManager.shared.makeClient(for: serverID) else { continue }
            for start in stride(from: 0, to: refs.count, by: Self.batchSize) {
                let batch = Array(refs[start..<min(start + Self.batchSize, refs.count)])
                do {
                    let fetched = try await client.getItemsWithUserData(itemIds: batch.map(\.itemID))
                    let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for ref in batch {
                        if let item = byID[ref.itemID], let data = item.userData {
                            updated[ref.recordID] = ServerWatchState(
                                userData: data,
                                communityRating: item.communityRating
                            )
                        }
                    }
                } catch {
                    logger.info("Watch state refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Drop entries for downloads that no longer exist.
        let live = Set(items.map(\.recordID))
        updated = updated.filter { live.contains($0.key) }
        guard updated != serverStates else { return }
        serverStates = updated
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(serverStates) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
