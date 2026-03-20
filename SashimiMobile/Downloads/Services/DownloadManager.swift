import Foundation
import SwiftData
import UIKit

// swiftlint:disable type_body_length
// DownloadManager coordinates background downloads, URLSession delegate, and SwiftData persistence

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    private static let sessionIdentifier = "com.mondominator.sashimi.mobile.downloads"
    private static let taskMapKey = "downloadTaskMap"

    @Published var activeDownloads: [String: Double] = [:] // itemId -> progress
    @Published var stateVersion: Int = 0 // bumped on any download state change

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

    private func taskKey(_ taskIdentifier: Int) -> String {
        String(taskIdentifier)
    }

    // Pending image/subtitle downloads (non-background, fire-and-forget)
    private var pendingAssetTasks: [String: [Task<Void, Never>]] = [:]

    private let persistence = DownloadPersistence()

    // Serial download queue
    private var downloadQueue: [(item: BaseItemDto, quality: DownloadQuality)] = []
    private var currentDownloadItemId: String?

    // Progress throttling
    private var pendingProgress: [String: Double] = [:]
    private var lastProgressSave: [String: Date] = [:]
    private var progressTimer: Timer?

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

    func enqueueDownload(item: BaseItemDto, quality: DownloadQuality) {
        guard insertQueuedRecord(item: item, quality: quality) else { return }
        downloadQueue.append((item: item, quality: quality))
        stateVersion += 1
        if currentDownloadItemId == nil {
            startNextDownload()
        }
    }

    /// Insert a queued download record on the main actor's context so @Query sees it immediately.
    private func insertQueuedRecord(item: BaseItemDto, quality: DownloadQuality) -> Bool {
        guard let context = mainContext else { return false }
        let itemId = item.id
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        if let existing = try? context.fetch(descriptor).first {
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

    private func startNextDownload() {
        guard !downloadQueue.isEmpty else {
            currentDownloadItemId = nil
            stopProgressTimer()
            return
        }

        let (item, quality) = downloadQueue.removeFirst()
        let itemId = item.id

        // Check disk space
        let availableSpace = DownloadFileManager.availableDiskSpace()
        if availableSpace < 500 * 1024 * 1024 {
            persistence.updateStatus(
                itemId: itemId,
                status: .failed,
                errorMessage: "Not enough disk space. Available: \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file))"
            )
            stateVersion += 1
            startNextDownload()
            return
        }

        guard let downloadURL = DownloadURLBuilder.downloadURL(itemId: itemId, quality: quality) else {
            persistence.updateStatus(itemId: itemId, status: .failed, errorMessage: "Could not build download URL")
            stateVersion += 1
            startNextDownload()
            return
        }

        do {
            try DownloadFileManager.createItemDirectory(for: itemId)
        } catch {
            persistence.updateStatus(itemId: itemId, status: .failed, errorMessage: "Could not create directory: \(error.localizedDescription)")
            stateVersion += 1
            startNextDownload()
            return
        }

        let task = backgroundSession.downloadTask(with: downloadURL)
        var map = taskIdMap
        map[taskKey(task.taskIdentifier)] = itemId
        taskIdMap = map

        currentDownloadItemId = itemId
        task.resume()
        persistence.updateStatus(itemId: itemId, status: .downloading)
        preparingItems.insert(itemId)
        pendingProgress[itemId] = 0
        stateVersion += 1
        startProgressTimer()

        // Download assets in background
        downloadAssets(for: item)
    }

    private func dequeueNext() {
        currentDownloadItemId = nil
        startNextDownload()
    }

    private func deleteRecordFromMainContext(itemId: String) {
        guard let context = mainContext else { return }
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        if let record = try? context.fetch(descriptor).first {
            context.delete(record)
            try? context.save()
        }
    }

    func pauseDownload(itemId: String) {
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where self.taskIdMap[self.taskKey(task.taskIdentifier)] == itemId {
                if let downloadTask = task as? URLSessionDownloadTask {
                    downloadTask.cancel(byProducingResumeData: { _ in })
                } else {
                    task.cancel()
                }
                Task { @MainActor in
                    self.persistence.updateStatus(itemId: itemId, status: .paused)
                    self.pendingProgress.removeValue(forKey: itemId)
                    self.activeDownloads.removeValue(forKey: itemId)
                    self.preparingItems.remove(itemId)
                }
                break
            }
        }
    }

    func cancelDownload(itemId: String) async {
        let tasks = await backgroundSession.allTasks
        for task in tasks where taskIdMap[taskKey(task.taskIdentifier)] == itemId {
            task.cancel()
            var map = taskIdMap
            map.removeValue(forKey: taskKey(task.taskIdentifier))
            taskIdMap = map
        }

        pendingAssetTasks[itemId]?.forEach { $0.cancel() }
        pendingAssetTasks.removeValue(forKey: itemId)

        pendingProgress.removeValue(forKey: itemId)
        activeDownloads.removeValue(forKey: itemId)
        preparingItems.remove(itemId)
        lastProgressSave.removeValue(forKey: itemId)

        try? DownloadFileManager.deleteItemDirectory(for: itemId)
        deleteRecordFromMainContext(itemId: itemId)

        // Manage queue
        if itemId == currentDownloadItemId {
            dequeueNext()
        } else {
            downloadQueue.removeAll { $0.item.id == itemId }
        }
    }

    func deleteDownload(itemId: String) async {
        await cancelDownload(itemId: itemId)
        stateVersion += 1
    }

    func retryDownload(itemId: String) async {
        guard let quality = persistence.fetchQuality(itemId: itemId) else { return }

        guard let freshItem = try? await JellyfinClient.shared.getItem(itemId: itemId) else {
            persistence.updateStatus(itemId: itemId, status: .failed, errorMessage: "Could not fetch item info")
            return
        }

        await cancelDownload(itemId: itemId)
        enqueueDownload(item: freshItem, quality: quality)
    }

    func downloadStatus(for itemId: String) -> DownloadedItem? {
        guard let context = mainContext else { return nil }
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        return try? context.fetch(descriptor).first
    }

    func isDownloaded(itemId: String) -> Bool {
        downloadStatus(for: itemId)?.isComplete ?? false
    }

    func localVideoURL(for itemId: String) -> URL? {
        guard let record = downloadStatus(for: itemId), record.isComplete else { return nil }
        return record.videoFileURL
    }

    func offlinePlaybackPosition(for itemId: String) -> Int64? {
        guard let context = mainContext else { return nil }
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        guard let record = try? context.fetch(descriptor).first else { return nil }
        return record.lastPlaybackPositionTicks > 0 ? record.lastPlaybackPositionTicks : nil
    }

    // MARK: - Offline Progress Tracking

    func savePlaybackPosition(itemId: String, positionTicks: Int64) {
        persistence.savePlaybackPosition(itemId: itemId, positionTicks: positionTicks)
    }

    func syncPendingProgress() async {
        let pendingItems = persistence.fetchPendingSync()
        for item in pendingItems {
            do {
                try await JellyfinClient.shared.reportPlaybackStopped(
                    itemId: item.itemId,
                    positionTicks: item.positionTicks
                )
                persistence.clearSyncFlag(itemId: item.itemId)
            } catch {
                // Server unreachable — will retry next launch
            }
        }
    }

    // MARK: - Season Downloads

    func downloadSeason(episodes: [BaseItemDto], quality: DownloadQuality) {
        let inserted = episodes.filter { insertQueuedRecord(item: $0, quality: quality) }
        for episode in inserted {
            downloadQueue.append((item: episode, quality: quality))
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
        activeDownloads = [:]

        downloadQueue.removeAll()
        currentDownloadItemId = nil
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

    private func reconnectTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                var activeTaskItemIds: Set<String> = []
                for task in tasks {
                    if let itemId = self.taskIdMap[self.taskKey(task.taskIdentifier)] {
                        if task.state == .running {
                            self.pendingProgress[itemId] = 0
                            self.activeDownloads[itemId] = 0
                            self.persistence.updateStatus(itemId: itemId, status: .downloading)
                            self.currentDownloadItemId = itemId
                            self.startProgressTimer()
                            activeTaskItemIds.insert(itemId)
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
            if isIncomplete && !activeTaskItemIds.contains(item.itemId) {
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
            await retryDownload(itemId: item.itemId)
        }
    }

    private func downloadAssets(for item: BaseItemDto) {
        let itemId = item.id

        let posterTask = Task {
            await downloadImage(
                url: DownloadURLBuilder.posterURL(itemId: itemId),
                destination: DownloadFileManager.posterPath(for: itemId),
                itemId: itemId,
                keyPath: "posterFileName",
                fileName: "poster.jpg"
            )
        }

        let backdropTask = Task {
            await downloadImage(
                url: DownloadURLBuilder.backdropURL(itemId: itemId),
                destination: DownloadFileManager.backdropPath(for: itemId),
                itemId: itemId,
                keyPath: "backdropFileName",
                fileName: "backdrop.jpg"
            )
        }

        // For episodes, also save the series poster for offline browsing
        let seriesPosterTask = Task {
            if item.type == .episode, let seriesId = item.seriesId {
                let seriesPosterDest = DownloadFileManager.itemDirectory(for: itemId)
                    .appendingPathComponent("series_poster.jpg")
                guard !FileManager.default.fileExists(atPath: seriesPosterDest.path) else { return }
                await downloadImage(
                    url: DownloadURLBuilder.posterURL(itemId: seriesId),
                    destination: seriesPosterDest,
                    itemId: itemId,
                    keyPath: "",
                    fileName: ""
                )
            }
        }

        let subtitleTask = Task {
            await downloadSubtitles(for: item)
        }

        pendingAssetTasks[itemId] = [posterTask, backdropTask, seriesPosterTask, subtitleTask]
    }

    private func downloadImage(url: URL?, destination: URL, itemId: String, keyPath: String, fileName: String) async {
        guard let url else { return }
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            try DownloadFileManager.moveFile(from: tempURL, to: destination)
            if keyPath == "posterFileName" {
                persistence.updatePosterFileName(itemId: itemId, fileName: fileName)
            } else if keyPath == "backdropFileName" {
                persistence.updateBackdropFileName(itemId: itemId, fileName: fileName)
            }
        } catch {
            // Best-effort: images are not critical
        }
    }

    private func downloadSubtitles(for item: BaseItemDto) async {
        guard let playbackInfo = try? await JellyfinClient.shared.getPlaybackInfo(itemId: item.id, maxBitrate: nil) else {
            return
        }

        guard let mediaSource = playbackInfo.mediaSources?.first else { return }
        let subtitleStreams = mediaSource.subtitleStreams

        let itemId = item.id
        try? DownloadFileManager.createSubtitlesDirectory(for: itemId)

        for stream in subtitleStreams {
            guard let index = stream.index,
                  let language = stream.language ?? stream.displayTitle else {
                continue
            }

            guard let url = DownloadURLBuilder.subtitleURL(itemId: itemId, subtitleIndex: index) else {
                continue
            }

            let fileName = "\(index)_\(language).vtt"
            let destination = DownloadFileManager.subtitlePath(for: itemId, index: index, language: language)

            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                try DownloadFileManager.moveFile(from: tempURL, to: destination)
                persistence.addSubtitle(
                    itemId: itemId,
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

        let destination = DownloadFileManager.videoPath(for: itemId, container: ext)
        let moveError: Error?
        do {
            try DownloadFileManager.moveFile(from: location, to: destination)
            moveError = nil
        } catch {
            moveError = error
        }

        Task { @MainActor in
            if let moveError {
                self.persistence.updateStatus(itemId: itemId, status: .failed, errorMessage: "File move failed: \(moveError.localizedDescription)")
            } else {
                self.persistence.markCompleted(
                    itemId: itemId,
                    videoFileName: "video.\(ext)",
                    totalBytes: DownloadFileManager.itemSize(for: itemId)
                )
            }

            self.pendingProgress.removeValue(forKey: itemId)
            self.activeDownloads.removeValue(forKey: itemId)
            self.preparingItems.remove(itemId)
            self.lastProgressSave.removeValue(forKey: itemId)
            self.stateVersion += 1

            var map = self.taskIdMap
            map.removeValue(forKey: self.taskKey(taskId))
            self.taskIdMap = map

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

            // Update in-memory progress (published on timer)
            self.pendingProgress[itemId] = progress

            // Clear preparing state once any bytes flow
            if totalBytesWritten > 0 {
                self.preparingItems.remove(itemId)
            }

            // Throttle SwiftData writes to every 5s per item
            let now = Date()
            let lastSave = self.lastProgressSave[itemId] ?? .distantPast
            if now.timeIntervalSince(lastSave) >= 5 {
                self.lastProgressSave[itemId] = now
                self.persistence.updateProgress(
                    itemId: itemId,
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
            self.persistence.updateStatus(itemId: itemId, status: .failed, errorMessage: error.localizedDescription)
            self.pendingProgress.removeValue(forKey: itemId)
            self.activeDownloads.removeValue(forKey: itemId)
            self.preparingItems.remove(itemId)

            var map = self.taskIdMap
            map.removeValue(forKey: self.taskKey(taskId))
            self.taskIdMap = map

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
