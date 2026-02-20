import Foundation
import SwiftData
import UIKit

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
    private var modelContainer: ModelContainer?

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
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - Public API

    func startDownload(item: BaseItemDto, quality: DownloadQuality) async {
        guard let container = modelContainer else { return }

        let itemId = item.id
        let context = ModelContext(container)

        // Check if already downloaded or downloading
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        if let existing = try? context.fetch(descriptor).first {
            if existing.status == .completed || existing.status == .downloading || existing.status == .queued {
                return // Already exists
            }
            // Re-download failed item
            context.delete(existing)
        }

        // Create download record
        let downloadedItem = DownloadedItem(
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

        context.insert(downloadedItem)
        try? context.save()

        // Check available disk space (require at least 500MB)
        let availableSpace = DownloadFileManager.availableDiskSpace()
        let minimumRequired: Int64 = 500 * 1024 * 1024
        if availableSpace < minimumRequired {
            await updateStatus(
                itemId: itemId,
                status: .failed,
                errorMessage: "Not enough disk space. Available: \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file))"
            )
            return
        }

        // Start the video download
        guard let downloadURL = DownloadURLBuilder.downloadURL(itemId: itemId, quality: quality) else {
            await updateStatus(itemId: itemId, status: .failed, errorMessage: "Could not build download URL")
            return
        }

        do {
            try DownloadFileManager.createItemDirectory(for: itemId)
        } catch {
            await updateStatus(itemId: itemId, status: .failed, errorMessage: "Could not create directory: \(error.localizedDescription)")
            return
        }

        let task = backgroundSession.downloadTask(with: downloadURL)
        var map = taskIdMap
        map[taskKey(task.taskIdentifier)] = itemId
        taskIdMap = map

        task.resume()
        await updateStatus(itemId: itemId, status: .downloading)
        activeDownloads[itemId] = 0

        // Download images and subtitles concurrently (non-background, best-effort)
        downloadAssets(for: item)
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
                    await self.updateStatus(itemId: itemId, status: .paused)
                    self.activeDownloads.removeValue(forKey: itemId)
                }
                break
            }
        }
    }

    func cancelDownload(itemId: String) async {
        // Cancel background task
        let tasks = await backgroundSession.allTasks
        for task in tasks where taskIdMap[taskKey(task.taskIdentifier)] == itemId {
            task.cancel()
            var map = taskIdMap
            map.removeValue(forKey: taskKey(task.taskIdentifier))
            taskIdMap = map
        }

        // Cancel asset tasks
        pendingAssetTasks[itemId]?.forEach { $0.cancel() }
        pendingAssetTasks.removeValue(forKey: itemId)

        activeDownloads.removeValue(forKey: itemId)

        // Delete files
        try? DownloadFileManager.deleteItemDirectory(for: itemId)

        // Delete SwiftData record
        await deleteRecord(itemId: itemId)
    }

    func deleteDownload(itemId: String) async {
        await cancelDownload(itemId: itemId)
        stateVersion += 1
    }

    func retryDownload(itemId: String) async {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)

        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        guard let record = try? context.fetch(descriptor).first else { return }

        // Re-fetch the item from Jellyfin for fresh metadata
        guard let freshItem = try? await JellyfinClient.shared.getItem(itemId: itemId) else {
            await updateStatus(itemId: itemId, status: .failed, errorMessage: "Could not fetch item info")
            return
        }

        let quality = record.downloadQuality
        // Delete old record and restart
        await cancelDownload(itemId: itemId)
        await startDownload(item: freshItem, quality: quality)
    }

    func downloadStatus(for itemId: String) -> DownloadedItem? {
        guard let container = modelContainer else { return nil }
        let context = ModelContext(container)
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

    /// Get the last saved offline playback position for a downloaded item
    func offlinePlaybackPosition(for itemId: String) -> Int64? {
        guard let container = modelContainer else { return nil }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)

        guard let record = try? context.fetch(descriptor).first else { return nil }
        return record.lastPlaybackPositionTicks > 0 ? record.lastPlaybackPositionTicks : nil
    }

    // MARK: - Offline Progress Tracking

    /// Save playback position for a downloaded item (called when player stops)
    func savePlaybackPosition(itemId: String, positionTicks: Int64) {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)

        guard let record = try? context.fetch(descriptor).first else { return }
        record.lastPlaybackPositionTicks = positionTicks
        record.needsProgressSync = true
        try? context.save()
    }

    /// Sync any pending offline progress back to the Jellyfin server
    func syncPendingProgress() async {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.needsProgressSync == true }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)

        guard let pendingItems = try? context.fetch(descriptor), !pendingItems.isEmpty else { return }

        for item in pendingItems {
            do {
                try await JellyfinClient.shared.reportPlaybackStopped(
                    itemId: item.itemId,
                    positionTicks: item.lastPlaybackPositionTicks
                )
                // Successfully synced — clear the flag
                item.needsProgressSync = false
                try? context.save()
            } catch {
                // Server unreachable — will retry next launch
            }
        }
    }

    // MARK: - Season Downloads

    func downloadSeason(episodes: [BaseItemDto], quality: DownloadQuality) async {
        for episode in episodes {
            await startDownload(item: episode, quality: quality)
        }
    }

    // MARK: - Delete All

    func deleteAllDownloads() async {
        guard let container = modelContainer else { return }

        // Cancel all active tasks
        let tasks = await backgroundSession.allTasks
        tasks.forEach { $0.cancel() }
        taskIdMap = [:]
        activeDownloads = [:]

        // Delete all files
        try? DownloadFileManager.deleteAllDownloads()

        // Delete all records
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedItem>()
        if let items = try? context.fetch(descriptor) {
            items.forEach { context.delete($0) }
            try? context.save()
        }
    }

    // MARK: - Private Helpers

    private func reconnectTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    if let itemId = self.taskIdMap[self.taskKey(task.taskIdentifier)] {
                        if task.state == .running {
                            self.activeDownloads[itemId] = 0
                            await self.updateStatus(itemId: itemId, status: .downloading)
                        }
                    }
                }
            }
        }
    }

    private func updateStatus(itemId: String, status: DownloadStatus, errorMessage: String? = nil) async {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)

        guard let record = try? context.fetch(descriptor).first else { return }
        record.status = status
        record.errorMessage = errorMessage
        if status == .completed {
            record.dateCompleted = Date()
            record.progress = 1.0
        }
        try? context.save()
    }

    private func updateProgress(itemId: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64) async {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)

        guard let record = try? context.fetch(descriptor).first else { return }
        record.progress = progress
        record.downloadedBytes = downloadedBytes
        record.totalBytes = totalBytes
        try? context.save()

        activeDownloads[itemId] = progress
    }

    private func deleteRecord(itemId: String) async {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)

        if let record = try? context.fetch(descriptor).first {
            context.delete(record)
            try? context.save()
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

        let subtitleTask = Task {
            await downloadSubtitles(for: item)
        }

        pendingAssetTasks[itemId] = [posterTask, backdropTask, subtitleTask]
    }

    private func downloadImage(url: URL?, destination: URL, itemId: String, keyPath: String, fileName: String) async {
        guard let url else { return }
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            try DownloadFileManager.moveFile(from: tempURL, to: destination)

            // Update record
            guard let container = modelContainer else { return }
            let context = ModelContext(container)
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }

            if keyPath == "posterFileName" {
                record.posterFileName = fileName
            } else if keyPath == "backdropFileName" {
                record.backdropFileName = fileName
            }
            try? context.save()
        } catch {
            // Best-effort: images are not critical
        }
    }

    private func downloadSubtitles(for item: BaseItemDto) async {
        // Get playback info to find subtitle streams
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

                // Save subtitle record
                guard let container = modelContainer else { return }
                let context = ModelContext(container)
                let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
                let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
                guard let record = try? context.fetch(descriptor).first else { return }

                let subtitle = DownloadedSubtitle(
                    language: language,
                    displayTitle: stream.displayTitle ?? language,
                    subtitleIndex: index,
                    fileName: fileName
                )
                record.subtitles.append(subtitle)
                try? context.save()
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

        // Now dispatch to main actor for SwiftData updates
        Task { @MainActor in
            if let moveError {
                await self.updateStatus(itemId: itemId, status: .failed, errorMessage: "File move failed: \(moveError.localizedDescription)")
            } else {
                guard let container = self.modelContainer else { return }
                let context = ModelContext(container)
                let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
                let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)

                if let record = try? context.fetch(descriptor).first {
                    record.videoFileName = "video.\(ext)"
                    record.totalBytes = DownloadFileManager.itemSize(for: itemId)
                    record.status = .completed
                    record.dateCompleted = Date()
                    record.progress = 1.0
                    try? context.save()
                }
            }

            self.activeDownloads.removeValue(forKey: itemId)
            self.stateVersion += 1

            var map = self.taskIdMap
            map.removeValue(forKey: self.taskKey(taskId))
            self.taskIdMap = map
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
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        Task { @MainActor in
            guard let itemId = taskIdMap[taskKey(taskId)] else { return }
            await updateProgress(
                itemId: itemId,
                progress: progress,
                downloadedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
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
            guard let itemId = taskIdMap[taskKey(taskId)] else { return }
            await updateStatus(itemId: itemId, status: .failed, errorMessage: error.localizedDescription)
            activeDownloads.removeValue(forKey: itemId)

            var map = taskIdMap
            map.removeValue(forKey: taskKey(taskId))
            taskIdMap = map
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
