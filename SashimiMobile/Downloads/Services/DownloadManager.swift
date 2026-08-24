import Foundation
import SwiftData
import UIKit

// swiftlint:disable type_body_length file_length
// DownloadManager coordinates background downloads, URLSession delegate, and SwiftData persistence:
// a large but cohesive type; splitting it would require a risky refactor of the URLSession delegate wiring.

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    nonisolated private static let sessionIdentifier = "com.mondominator.sashimi.mobile.downloads"
    nonisolated private static let taskMapKey = "downloadTaskMap"
    nonisolated private static let taskServerMapKey = "downloadTaskServerMap"

    @Published var activeDownloads: [String: Double] = [:] // recordID -> progress
    @Published var stateVersion: Int = 0 // bumped on any download state change
    @Published var downloadSpeed: String = "" // human-readable bandwidth

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var backgroundSession: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?
    private(set) var modelContainer: ModelContainer?
    private var cachedContext: ModelContext?

    // Maps URLSessionTask.taskIdentifier (as String) -> itemId for surviving app relaunches
    // UserDefaults plist format requires String keys, so we store Int taskIdentifiers as Strings
    private var taskIdMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.taskMapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.taskMapKey) }
    }

    private var taskServerMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.taskServerMapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.taskServerMapKey) }
    }

    private func taskKey(_ taskIdentifier: Int) -> String {
        String(taskIdentifier)
    }

    private func downloadKey(itemId: String, serverID: String?) -> String {
        "\(serverID ?? "legacy"):\(itemId)"
    }

    // Pending image/subtitle downloads (non-background, fire-and-forget)
    private var pendingAssetTasks: [String: [Task<Void, Never>]] = [:]

    private let persistence = DownloadPersistence()

    private struct ServerDownloadContext {
        let server: ServerConfig
        let token: String
    }

    // Serial download queue
    private struct QueuedDownload {
        let item: BaseItemDto
        let quality: DownloadQuality
        let serverID: String?
    }

    private struct ImageDownload {
        let url: URL?
        let token: String
        let destination: URL
        let itemID: String
        let keyPath: String
        let fileName: String
    }

    private var downloadQueue: [QueuedDownload] = []
    private var currentDownloadItemId: String?
    private var currentDownloadServerID: String?
    var queuedCount: Int { downloadQueue.count }

    // Progress throttling
    private var pendingProgress: [String: Double] = [:]
    private var lastProgressSave: [String: Date] = [:]
    private var progressTimer: Timer?

    // Bandwidth tracking
    private var lastBytesWritten: Int64 = 0
    private var lastSpeedCheck: Date = .distantPast

    // In-memory preparing state (items waiting for first bytes from server)
    @Published var preparingItems: Set<String> = []

    // Toast notification
    @Published var toastMessage: String?

    override private init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // Reconnect any in-flight downloads from previous launch
        reconnectTasks()
    }

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
        self.cachedContext = ModelContext(container)
        persistence.setModelContainer(container)
    }

    /// Reusable main-actor context for reads. Avoids creating throwaway ModelContexts per call.
    private var mainContext: ModelContext? {
        cachedContext
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func publishProgress() {
        guard !pendingProgress.isEmpty else { return }
        activeDownloads = pendingProgress
    }

    // MARK: - Public API

    func enqueueDownload(item: BaseItemDto, quality: DownloadQuality, serverID: String? = nil) {
        let resolvedServerID = serverID ?? SessionManager.shared.activeServerId
        guard insertQueuedRecord(item: item, quality: quality, serverID: resolvedServerID) else { return }
        downloadQueue.append(QueuedDownload(item: item, quality: quality, serverID: resolvedServerID))
        stateVersion += 1
        if currentDownloadItemId == nil {
            startNextDownload()
        }
    }

    /// Insert a queued download record on the main actor's context so @Query sees it immediately.
    private func insertQueuedRecord(item: BaseItemDto, quality: DownloadQuality, serverID: String?) -> Bool {
        guard let context = mainContext else { return false }
        let itemId = item.id
        let existing = mainRecord(itemId: itemId, serverID: serverID)
        if let existing {
            if existing.status == .completed || existing.status == .downloading
                || existing.status == .preparing || existing.status == .queued {
                return false
            }
            context.delete(existing)
        }
        let record = DownloadedItem(
            itemId: itemId,
            name: item.name,
            itemType: item.type ?? .unknown,
            quality: quality,
            serverID: serverID,
            seriesName: item.seriesName,
            seasonNumber: item.parentIndexNumber,
            episodeNumber: item.indexNumber,
            overview: item.overview,
            runTimeTicks: item.runTimeTicks,
            productionYear: item.productionYear,
            seriesId: item.seriesId,
            seasonId: item.seasonId
        )
        context.insert(record)
        try? context.save()
        return true
    }

    private func mainRecord(itemId: String, serverID: String?) -> DownloadedItem? {
        guard let context = mainContext,
              let records = try? context.fetch(FetchDescriptor<DownloadedItem>()) else { return nil }
        if let serverID {
            if let exact = records.first(where: { $0.itemId == itemId && $0.serverID == serverID }) {
                return exact
            }
            guard serverID == SessionManager.shared.activeServerId,
                  let legacy = records.first(where: { $0.itemId == itemId && $0.serverID == nil }) else {
                return nil
            }
            // Bind pre-multi-server records to the active server before they
            // are reused. Move their files so the old download remains intact.
            guard (try? DownloadFileManager.migrateItemDirectory(itemId: itemId, to: serverID)) == true else {
                return nil
            }
            legacy.serverID = serverID
            try? context.save()
            return legacy
        }
        return records.first { $0.itemId == itemId && $0.serverID == nil }
            ?? records.first { $0.itemId == itemId }
    }

    private func startNextDownload() {
        guard !downloadQueue.isEmpty else {
            currentDownloadItemId = nil
            currentDownloadServerID = nil
            stopProgressTimer()
            downloadSpeed = ""
            return
        }

        // Reset speed tracking for new download
        lastBytesWritten = 0
        lastSpeedCheck = .distantPast

        let queued = downloadQueue.removeFirst()
        let item = queued.item
        let quality = queued.quality
        let serverID = queued.serverID
        let itemId = item.id

        // Check disk space
        let availableSpace = DownloadFileManager.availableDiskSpace()
        if availableSpace < 500 * 1024 * 1024 {
            persistence.updateStatus(
                itemId: itemId,
                serverID: serverID,
                status: .failed,
                errorMessage: "Not enough disk space. Available: \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file))"
            )
            stateVersion += 1
            startNextDownload()
            return
        }

        // Mark this item as the current download synchronously so re-entrant
        // enqueues don't kick off a second concurrent download while we await
        // the (only-for-.original) compatibility check below.
        currentDownloadItemId = itemId
        currentDownloadServerID = serverID

        // Resolve the effective quality — for `.original`, verify the raw source
        // will direct-play on this device; if not (or on any error) downgrade to
        // `.high` and persist the downgrade — then start the actual download.
        Task { [weak self] in
            guard let self else { return }
            let effectiveQuality = await self.resolveEffectiveQuality(
                itemId: itemId,
                requested: quality,
                serverID: serverID
            )
            self.beginDownload(item: item, quality: effectiveQuality, serverID: serverID)
        }
    }

    /// For `.original`, fetches playback info and downgrades to `.high` unless
    /// the source can direct-play (fails closed on missing source / error).
    /// Non-`.original` qualities skip the network call entirely. Persists the
    /// downgrade so the DB/UI reflect what was actually downloaded.
    private func resolveEffectiveQuality(
        itemId: String,
        requested: DownloadQuality,
        serverID: String?
    ) async -> DownloadQuality {
        guard requested == .original else { return requested }

        let compatible: Bool
        do {
            // Downloads stay on the AVPlayer profile until Phase 5: an MKV
            // downloaded under a VLC profile would be one AVPlayer can't open.
            let client = try await client(for: serverID)
            let info = try await client.getPlaybackInfo(itemId: itemId, engine: .avFoundation)
            compatible = info.mediaSources?.first
                .map { DeviceMediaCompatibility.canDirectPlayOnDevice($0) } ?? false
        } catch {
            compatible = false // fail closed
        }

        let effective = DownloadQuality.effectiveQuality(requested: requested, sourceIsCompatible: compatible)
        if effective != requested {
            persistence.updateQuality(itemId: itemId, serverID: serverID, quality: effective)
            // Also reflect the downgrade in the UI's source of truth (mainContext).
            // The persistence write above goes to a private queue context, which the
            // @Query-backed UI doesn't observe — without this, a completed download
            // can keep showing "Original" even though the file is actually High.
            if let context = mainContext {
                if let record = mainRecord(itemId: itemId, serverID: serverID) {
                    record.downloadQuality = effective
                    try? context.save()
                }
            }
        }
        return effective
    }

    /// Builds the download URL with the (already-resolved) effective quality and
    /// starts the background download task.
    private func beginDownload(item: BaseItemDto, quality: DownloadQuality, serverID: String?) {
        let itemId = item.id

        // The item may have been cancelled while the compatibility check was in
        // flight; bail if it's no longer the current download.
        guard currentDownloadItemId == itemId,
              currentDownloadServerID == serverID else { return }

        // URLRequest (not bare URL) so the token travels in a header and the
        // background task keeps it across app relaunches.
        guard let context = serverContext(for: serverID),
              let downloadURL = DownloadURLBuilder.downloadURL(
                  itemId: itemId,
                  quality: quality,
                  serverURL: context.server.url
              ),
              let downloadRequest = DownloadURLBuilder.authorizedRequest(
                  for: downloadURL,
                  accessToken: context.token
              ) else {
            persistence.updateStatus(
                itemId: itemId,
                serverID: serverID,
                status: .failed,
                errorMessage: "Could not build download URL"
            )
            stateVersion += 1
            startNextDownload()
            return
        }

        do {
            try DownloadFileManager.createItemDirectory(for: itemId, serverID: serverID)
        } catch {
            persistence.updateStatus(
                itemId: itemId,
                serverID: serverID,
                status: .failed,
                errorMessage: "Could not create directory: \(error.localizedDescription)"
            )
            stateVersion += 1
            startNextDownload()
            return
        }

        let task = backgroundSession.downloadTask(with: downloadRequest)
        var map = taskIdMap
        map[taskKey(task.taskIdentifier)] = itemId
        taskIdMap = map
        var serverMap = taskServerMap
        if let serverID {
            serverMap[taskKey(task.taskIdentifier)] = serverID
        }
        taskServerMap = serverMap

        // currentDownloadItemId was already set synchronously in startNextDownload
        // so re-entrant enqueues couldn't start a second concurrent download.
        task.resume()
        persistence.updateStatus(itemId: itemId, serverID: serverID, status: .downloading)
        let key = downloadKey(itemId: itemId, serverID: serverID)
        preparingItems.insert(key)
        pendingProgress[key] = 0
        stateVersion += 1
        startProgressTimer()

        // Download assets in background
        downloadAssets(for: item, server: context.server, token: context.token)
    }

    private func dequeueNext() {
        currentDownloadItemId = nil
        currentDownloadServerID = nil
        startNextDownload()
    }

    private func deleteRecordFromMainContext(itemId: String, serverID: String?) {
        guard let context = mainContext,
              let record = mainRecord(itemId: itemId, serverID: serverID) else { return }
        context.delete(record)
        try? context.save()
    }

    func cancelDownload(itemId: String, serverID: String? = nil) async {
        let tasks = await backgroundSession.allTasks
        for task in tasks where taskIdMap[taskKey(task.taskIdentifier)] == itemId
            && (serverID == nil || taskServerMap[taskKey(task.taskIdentifier)] == serverID) {
            task.cancel()
            var map = taskIdMap
            map.removeValue(forKey: taskKey(task.taskIdentifier))
            taskIdMap = map
            var serverMap = taskServerMap
            serverMap.removeValue(forKey: taskKey(task.taskIdentifier))
            taskServerMap = serverMap
        }

        let key = downloadKey(itemId: itemId, serverID: serverID)
        pendingAssetTasks[key]?.forEach { $0.cancel() }
        pendingAssetTasks.removeValue(forKey: key)

        pendingProgress.removeValue(forKey: key)
        activeDownloads.removeValue(forKey: key)
        preparingItems.remove(key)
        lastProgressSave.removeValue(forKey: key)

        try? DownloadFileManager.deleteItemDirectory(for: itemId, serverID: serverID)
        deleteRecordFromMainContext(itemId: itemId, serverID: serverID)

        // Manage queue
        if itemId == currentDownloadItemId
            && (serverID == nil || serverID == currentDownloadServerID) {
            dequeueNext()
        } else {
            downloadQueue.removeAll {
                $0.item.id == itemId && (serverID == nil || $0.serverID == serverID)
            }
        }
    }

    func deleteDownload(itemId: String, serverID: String? = nil) async {
        await cancelDownload(itemId: itemId, serverID: serverID)
        stateVersion += 1
    }

    func retryDownload(itemId: String, serverID: String? = nil) async {
        let record = downloadStatus(for: itemId, serverID: serverID)
        let resolvedServerID = serverID ?? record?.serverID
        guard let quality = persistence.fetchQuality(itemId: itemId, serverID: resolvedServerID) else { return }

        guard let client = try? await client(for: resolvedServerID),
              let freshItem = try? await client.getItem(itemId: itemId) else {
            persistence.updateStatus(
                itemId: itemId,
                serverID: resolvedServerID,
                status: .failed,
                errorMessage: "Could not fetch item info"
            )
            return
        }

        await cancelDownload(itemId: itemId, serverID: resolvedServerID)
        enqueueDownload(item: freshItem, quality: quality, serverID: resolvedServerID)
    }

    func downloadStatus(for itemId: String, serverID: String? = nil) -> DownloadedItem? {
        mainRecord(itemId: itemId, serverID: serverID ?? SessionManager.shared.activeServerId)
    }

    func isDownloaded(itemId: String, serverID: String? = nil) -> Bool {
        downloadStatus(for: itemId, serverID: serverID)?.isComplete ?? false
    }

    func localVideoURL(for itemId: String, serverID: String? = nil) -> URL? {
        guard let record = downloadStatus(for: itemId, serverID: serverID), record.isComplete else { return nil }
        return record.videoFileURL
    }

    /// The downloaded subtitle tracks for an item, in a form the shared player
    /// can consume. Without this the .vtt files written at download time were
    /// never read by anything.
    func offlineSubtitles(for itemId: String, serverID: String? = nil) -> [OfflineSubtitle] {
        guard let record = downloadStatus(for: itemId, serverID: serverID) else { return [] }
        return record.subtitles.compactMap { subtitle in
            let url = DownloadFileManager.subtitlesDirectory(for: itemId, serverID: record.serverID)
                .appendingPathComponent(subtitle.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return OfflineSubtitle(
                index: subtitle.subtitleIndex,
                language: subtitle.language,
                displayTitle: subtitle.displayTitle,
                fileURL: url
            )
        }
    }

    func offlinePlaybackPosition(for itemId: String, serverID: String? = nil) -> Int64? {
        guard let record = downloadStatus(for: itemId, serverID: serverID) else { return nil }
        return record.lastPlaybackPositionTicks > 0 ? record.lastPlaybackPositionTicks : nil
    }

    // MARK: - Offline Progress Tracking

    func savePlaybackPosition(itemId: String, serverID: String? = nil, positionTicks: Int64) {
        persistence.savePlaybackPosition(itemId: itemId, serverID: serverID, positionTicks: positionTicks)
    }

    func syncPendingProgress() async {
        let pendingItems = persistence.fetchPendingSync()
        for item in pendingItems {
            do {
                let client = try await client(for: item.serverID)
                try await client.reportPlaybackStopped(
                    itemId: item.itemID,
                    positionTicks: item.positionTicks
                )
                persistence.clearSyncFlag(itemId: item.itemID, serverID: item.serverID)
            } catch {
                // Server unreachable — will retry next launch
            }
        }
    }

    // MARK: - Season Downloads

    func downloadSeason(episodes: [BaseItemDto], quality: DownloadQuality, serverID: String? = nil) {
        let serverID = serverID ?? SessionManager.shared.activeServerId
        let inserted = episodes.filter { insertQueuedRecord(item: $0, quality: quality, serverID: serverID) }
        for episode in inserted {
            downloadQueue.append(QueuedDownload(item: episode, quality: quality, serverID: serverID))
        }
        let insertedCount = inserted.count
        guard insertedCount > 0 else { return }

        stateVersion += 1
        toastMessage = "Downloading \(insertedCount) episode\(insertedCount == 1 ? "" : "s")..."

        if currentDownloadItemId == nil {
            startNextDownload()
        }
    }

    // MARK: - Delete All

    func deleteAllDownloads() async {
        // Cancel all active tasks
        let tasks = await backgroundSession.allTasks
        tasks.forEach { $0.cancel() }
        taskIdMap = [:]
        taskServerMap = [:]
        activeDownloads = [:]

        downloadQueue.removeAll()
        currentDownloadItemId = nil
        currentDownloadServerID = nil
        pendingProgress.removeAll()
        preparingItems.removeAll()
        lastProgressSave.removeAll()
        stopProgressTimer()

        // Delete all files
        try? DownloadFileManager.deleteAllDownloads()

        // Delete all records
        persistence.deleteAllRecords()
    }

    // MARK: - Private Helpers

    private func serverContext(for serverID: String?) -> ServerDownloadContext? {
        let resolvedServerID = serverID ?? SessionManager.shared.activeServerId
        guard let resolvedServerID,
              let server = SessionManager.shared.servers.first(where: { $0.id == resolvedServerID }),
              let token = SessionManager.shared.token(for: server, allowLegacyFallback: true) else {
            return nil
        }
        return ServerDownloadContext(server: server, token: token)
    }

    private func client(for serverID: String?) async throws -> JellyfinClient {
        guard let context = serverContext(for: serverID) else {
            throw JellyfinError.notConfigured
        }
        let client = JellyfinClient()
        await client.configure(
            serverURL: context.server.url,
            accessToken: context.token,
            userId: context.server.userId
        )
        return client
    }

    private func reconnectTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                var activeTaskItemIds: Set<String> = []
                for task in tasks {
                    if let itemId = self.taskIdMap[self.taskKey(task.taskIdentifier)] {
                        if task.state == .running {
                            let serverID = self.taskServerMap[self.taskKey(task.taskIdentifier)]
                            let key = self.downloadKey(itemId: itemId, serverID: serverID)
                            self.pendingProgress[key] = 0
                            self.activeDownloads[key] = 0
                            self.preparingItems.insert(key)
                            self.persistence.updateStatus(
                                itemId: itemId,
                                serverID: serverID,
                                status: .downloading
                            )
                            self.currentDownloadItemId = itemId
                            self.currentDownloadServerID = serverID
                            self.startProgressTimer()
                            activeTaskItemIds.insert(key)
                        }
                    }
                }

                // Mark any "downloading"/"preparing" records without active tasks as failed
                // (stale from previous install/crash)
                self.cleanupStaleDownloads(activeTaskItemIds: activeTaskItemIds)
            }
        }
    }

    private func cleanupStaleDownloads(activeTaskItemIds: Set<String>) {
        guard let context = mainContext else { return }
        let descriptor = FetchDescriptor<DownloadedItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            let status = item.status
            let isIncomplete = status == .downloading || status == .preparing || status == .queued
            if isIncomplete && !activeTaskItemIds.contains(item.recordID) {
                item.status = .failed
                item.errorMessage = "Download interrupted. Tap retry to restart."
            }
        }
        try? context.save()
        stateVersion += 1
    }

    func restartAllFailed() async {
        guard let context = mainContext else { return }
        let descriptor = FetchDescriptor<DownloadedItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        let failedItems = items.filter { $0.status == .failed }
        for item in failedItems {
            await retryDownload(itemId: item.itemId, serverID: item.serverID)
        }
    }

    private func downloadAssets(for item: BaseItemDto, server: ServerConfig, token: String) {
        let itemId = item.id

        let posterTask = Task {
            await downloadImage(ImageDownload(
                url: DownloadURLBuilder.posterURL(itemId: itemId, serverURL: server.url),
                token: token,
                destination: DownloadFileManager.posterPath(for: itemId, serverID: server.id),
                itemID: itemId,
                keyPath: "posterFileName",
                fileName: "poster.jpg"
            ))
        }

        let backdropTask = Task {
            await downloadImage(ImageDownload(
                url: DownloadURLBuilder.backdropURL(itemId: itemId, serverURL: server.url),
                token: token,
                destination: DownloadFileManager.backdropPath(for: itemId, serverID: server.id),
                itemID: itemId,
                keyPath: "backdropFileName",
                fileName: "backdrop.jpg"
            ))
        }

        // For episodes, also save the series poster for offline browsing
        let seriesPosterTask = Task {
            if item.type == .episode, let seriesId = item.seriesId {
                let seriesPosterDest = DownloadFileManager.itemDirectory(for: itemId, serverID: server.id)
                    .appendingPathComponent("series_poster.jpg")
                guard !FileManager.default.fileExists(atPath: seriesPosterDest.path) else { return }
                await downloadImage(ImageDownload(
                    url: DownloadURLBuilder.posterURL(itemId: seriesId, serverURL: server.url),
                    token: token,
                    destination: seriesPosterDest,
                    itemID: itemId,
                    keyPath: "",
                    fileName: ""
                ))
            }
        }

        let subtitleTask = Task {
            await downloadSubtitles(for: item, server: server, token: token)
        }

        pendingAssetTasks[downloadKey(itemId: itemId, serverID: server.id)] = [
            posterTask,
            backdropTask,
            seriesPosterTask,
            subtitleTask
        ]
    }

    private func downloadImage(_ asset: ImageDownload) async {
        guard let url = asset.url,
              let request = DownloadURLBuilder.authorizedRequest(for: url, accessToken: asset.token) else { return }
        do {
            let (tempURL, _) = try await URLSession.shared.download(for: request)
            try DownloadFileManager.moveFile(from: tempURL, to: asset.destination)
            if asset.keyPath == "posterFileName" {
                persistence.updatePosterFileName(itemId: asset.itemID, fileName: asset.fileName)
            } else if asset.keyPath == "backdropFileName" {
                persistence.updateBackdropFileName(itemId: asset.itemID, fileName: asset.fileName)
            }
        } catch {
            // Best-effort: images are not critical
        }
    }

    private func downloadSubtitles(for item: BaseItemDto, server: ServerConfig, token: String) async {
        guard let client = try? await client(for: server.id),
              let playbackInfo = try? await client.getPlaybackInfo(
                  itemId: item.id,
                  itemType: item.type,
                  engine: .avFoundation,
                  maxBitrate: nil
              ) else {
            return
        }

        guard let mediaSource = playbackInfo.mediaSources?.first else { return }
        let subtitleStreams = mediaSource.subtitleStreams

        let itemId = item.id
        try? DownloadFileManager.createSubtitlesDirectory(for: itemId, serverID: server.id)

        for stream in subtitleStreams {
            guard let index = stream.index,
                  let language = stream.language ?? stream.displayTitle else {
                continue
            }

            guard let url = DownloadURLBuilder.subtitleURL(
                      itemId: itemId,
                      subtitleIndex: index,
                      serverURL: server.url
                  ),
                  let request = DownloadURLBuilder.authorizedRequest(for: url, accessToken: token) else {
                continue
            }

            let fileName = "\(index)_\(language).vtt"
            let destination = DownloadFileManager.subtitlePath(
                for: itemId,
                index: index,
                language: language,
                serverID: server.id
            )

            do {
                let (tempURL, _) = try await URLSession.shared.download(for: request)
                try DownloadFileManager.moveFile(from: tempURL, to: destination)
                persistence.addSubtitle(
                    itemId: itemId,
                    serverID: server.id,
                    language: language,
                    displayTitle: stream.displayTitle ?? language,
                    subtitleIndex: index,
                    fileName: fileName
                )
            } catch {
                // Best-effort: skip failed subtitles
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    // Background URLSession requires the file move and state cleanup to remain
    // in one synchronous callback before Apple's temporary file is removed.
    // swiftlint:disable:next function_body_length
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        let ext = downloadTask.response?.suggestedFilename?.components(separatedBy: ".").last ?? "mp4"

        // MUST move file synchronously — temp file at `location` is deleted when this callback returns
        let itemId: String? = UserDefaults.standard.dictionary(forKey: Self.taskMapKey)?[String(taskId)] as? String
        guard let itemId else { return }
        let serverID: String? = UserDefaults.standard.dictionary(forKey: Self.taskServerMapKey)?[String(taskId)] as? String

        // A background download task reports HTTP 4xx/5xx here (not as a
        // transport error), with the error page as the "downloaded" body.
        // Without this guard we'd move that page to video.mp4 and mark the
        // item COMPLETED — a broken file masquerading as a finished download.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Task { @MainActor in
                self.persistence.updateStatus(
                    itemId: itemId,
                    serverID: serverID,
                    status: .failed,
                    errorMessage: "Server returned HTTP \(http.statusCode)"
                )
                let key = self.downloadKey(itemId: itemId, serverID: serverID)
                self.pendingProgress.removeValue(forKey: key)
                self.activeDownloads.removeValue(forKey: key)
                self.preparingItems.remove(key)
                var map = self.taskIdMap
                map.removeValue(forKey: self.taskKey(taskId))
                self.taskIdMap = map
                var serverMap = self.taskServerMap
                serverMap.removeValue(forKey: self.taskKey(taskId))
                self.taskServerMap = serverMap
                self.stateVersion += 1
                self.dequeueNext()
            }
            return
        }

        let destination = DownloadFileManager.videoPath(for: itemId, container: ext, serverID: serverID)
        let moveError: Error?
        do {
            try DownloadFileManager.moveFile(from: location, to: destination)
            moveError = nil
        } catch {
            moveError = error
        }

        Task { @MainActor in
            if let moveError {
                self.persistence.updateStatus(
                    itemId: itemId,
                    serverID: serverID,
                    status: .failed,
                    errorMessage: "File move failed: \(moveError.localizedDescription)"
                )
            } else {
                self.persistence.markCompleted(
                    itemId: itemId,
                    serverID: serverID,
                    videoFileName: "video.\(ext)",
                    totalBytes: DownloadFileManager.itemSize(for: itemId, serverID: serverID)
                )
            }

            let key = self.downloadKey(itemId: itemId, serverID: serverID)
            self.pendingProgress.removeValue(forKey: key)
            self.activeDownloads.removeValue(forKey: key)
            self.preparingItems.remove(key)
            self.lastProgressSave.removeValue(forKey: key)
            self.stateVersion += 1

            var map = self.taskIdMap
            map.removeValue(forKey: self.taskKey(taskId))
            self.taskIdMap = map
            var serverMap = self.taskServerMap
            serverMap.removeValue(forKey: self.taskKey(taskId))
            self.taskServerMap = serverMap

            self.dequeueNext()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        // totalBytesExpectedToWrite is -1 for transcoded content (unknown size)
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1 // negative signals unknown total

        Task { @MainActor in
            guard let itemId = self.taskIdMap[self.taskKey(taskId)] else { return }
            let serverID = self.taskServerMap[self.taskKey(taskId)]
            let key = self.downloadKey(itemId: itemId, serverID: serverID)

            // Update in-memory progress (published on timer)
            self.pendingProgress[key] = progress

            // Clear preparing state once any bytes flow
            if totalBytesWritten > 0 {
                self.preparingItems.remove(key)
            }

            // Bandwidth tracking
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastSpeedCheck)
            if elapsed >= 1.0 {
                let bytesDelta = totalBytesWritten - self.lastBytesWritten
                if bytesDelta > 0 {
                    let bytesPerSecond = Double(bytesDelta) / elapsed
                    self.downloadSpeed = ByteCountFormatter.string(
                        fromByteCount: Int64(bytesPerSecond), countStyle: .file
                    ) + "/s"
                }
                self.lastBytesWritten = totalBytesWritten
                self.lastSpeedCheck = now
            }

            // Throttle SwiftData writes to every 5s per item
            let lastSave = self.lastProgressSave[key] ?? .distantPast
            if now.timeIntervalSince(lastSave) >= 5 {
                self.lastProgressSave[key] = now
                self.persistence.updateProgress(
                    itemId: itemId,
                    serverID: serverID,
                    progress: progress,
                    downloadedBytes: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        let taskId = task.taskIdentifier
        let nsError = error as NSError

        // Don't treat cancellation as an error
        if nsError.code == NSURLErrorCancelled { return }

        Task { @MainActor in
            guard let itemId = self.taskIdMap[self.taskKey(taskId)] else { return }
            let serverID = self.taskServerMap[self.taskKey(taskId)]
            let key = self.downloadKey(itemId: itemId, serverID: serverID)
            self.persistence.updateStatus(
                itemId: itemId,
                serverID: serverID,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            self.pendingProgress.removeValue(forKey: key)
            self.activeDownloads.removeValue(forKey: key)
            self.preparingItems.remove(key)

            var map = self.taskIdMap
            map.removeValue(forKey: self.taskKey(taskId))
            self.taskIdMap = map
            var serverMap = self.taskServerMap
            serverMap.removeValue(forKey: self.taskKey(taskId))
            self.taskServerMap = serverMap

            self.dequeueNext()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
