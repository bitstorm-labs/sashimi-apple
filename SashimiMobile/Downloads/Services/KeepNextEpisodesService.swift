import Combine
import Foundation
import MediaPlayer
import SwiftData
import UIKit

extension Notification.Name {
    /// Posted by DownloadManager when a download finishes and is saved.
    static let downloadDidComplete = Notification.Name("downloadDidComplete")
}

/// Keeps each opted-in show's next episodes downloaded: deletes the episodes
/// watched since they were downloaded and queues the next unwatched ones
/// through DownloadManager. Runs, debounced, when the app becomes active,
/// when the network comes back, after playback stops and after a download
/// completes; never offline and never while something is playing.
@MainActor
final class KeepNextEpisodesService {
    static let shared = KeepNextEpisodesService()

    private let store = KeepNextEpisodesStore.shared
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var isRunning = false
    private var rerunRequested = false
    private var started = false

    nonisolated private static let debounce: Duration = .seconds(3)

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, .playbackDidStop, .downloadDidComplete] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync() }
            })
        }
        NetworkMonitor.shared.$isConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
    }

    /// Debounced: a burst of triggers runs one sync.
    func scheduleSync(after delay: Duration = debounce) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.runSync()
        }
    }

    private func runSync() async {
        guard !isRunning else {
            rerunRequested = true
            return
        }
        isRunning = true
        defer {
            isRunning = false
            if rerunRequested {
                rerunRequested = false
                scheduleSync()
            }
        }
        for setting in store.activeSettings {
            // Re-checked per show: playback or a lost connection mid-run stops it.
            guard NetworkMonitor.shared.isConnected, !Self.isPlaybackActive else { return }
            await sync(setting)
        }
    }

    /// A player session is up (its Now Playing info is set from load until
    /// teardown, PiP included). The sync waits for `.playbackDidStop` rather
    /// than touching the show being watched.
    private static var isPlaybackActive: Bool {
        MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
    }

    private func sync(_ setting: KeepNextEpisodesSetting) async {
        guard let client = SessionManager.shared.makeClient(for: setting.serverID),
              let serverEpisodes = try? await client.getEpisodes(seriesId: setting.seriesId),
              // The setting may have changed while the episodes loaded.
              let current = store.setting(serverID: setting.serverID, seriesId: setting.seriesId) else { return }

        let records = DownloadManager.shared.seriesRecords(seriesId: setting.seriesId, serverID: setting.serverID)
        let plan = KeepNextEpisodesPlanner.plan(
            episodes: serverEpisodes.map(Self.plannerEpisode),
            downloads: records.map(Self.plannerDownload),
            count: current.count
        )
        guard !plan.isEmpty else { return }

        let manager = DownloadManager.shared
        for itemId in plan.delete {
            await manager.deleteDownload(itemId: itemId, serverID: setting.serverID)
        }
        let byID = Dictionary(serverEpisodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for itemId in plan.enqueue {
            guard let episode = byID[itemId] else { continue }
            manager.enqueueDownload(item: episode, quality: current.quality, serverID: setting.serverID)
        }
    }

    private static func plannerEpisode(_ episode: BaseItemDto) -> KeepNextEpisodesPlanner.Episode {
        KeepNextEpisodesPlanner.Episode(
            id: episode.id,
            isSpecial: BulkDownloadPlanner.isSpecial(episode),
            isPlayed: episode.userData?.played ?? false,
            lastPlayedDate: DateFormatting.parseDate(episode.userData?.lastPlayedDate)
        )
    }

    private static func plannerDownload(_ record: DownloadedItem) -> KeepNextEpisodesPlanner.Download {
        let runTime = record.runTimeTicks ?? 0
        let watchedLocally = runTime > 0
            && Double(record.lastPlaybackPositionTicks) / Double(runTime) >= DownloadWatchPolicy.playedFraction
        return KeepNextEpisodesPlanner.Download(
            itemId: record.itemId,
            dateAdded: record.dateAdded,
            isWatchedLocally: watchedLocally
        )
    }
}

extension DownloadManager {
    /// Every download record (any status) of a show's episodes on a server,
    /// newest first.
    func seriesRecords(seriesId: String, serverID: String) -> [DownloadedItem] {
        guard let modelContainer else { return [] }
        let descriptor = FetchDescriptor<DownloadedItem>(
            predicate: #Predicate { $0.serverID == serverID && $0.seriesId == seriesId },
            sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
        )
        return (try? ModelContext(modelContainer).fetch(descriptor)) ?? []
    }

    /// The quality the show was last downloaded at, if it ever was.
    func latestQuality(seriesId: String, serverID: String) -> DownloadQuality? {
        seriesRecords(seriesId: seriesId, serverID: serverID).first?.downloadQuality
    }
}
