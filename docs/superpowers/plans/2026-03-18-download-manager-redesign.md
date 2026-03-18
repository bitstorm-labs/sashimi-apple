# Download Manager Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign DownloadManager to use a serial download queue, offload SwiftData to a background helper, throttle progress updates, and provide user feedback (preparing state, toast notification).

**Architecture:** Keep `DownloadManager` as `@MainActor ObservableObject`. Create `DownloadPersistence` — a non-isolated helper class with a serial `DispatchQueue` and dedicated `ModelContext` for all SwiftData operations. Add a serial download queue (one video at a time). Throttle progress: URLSession callbacks write to a plain dict, a 0.5s timer publishes to `@Published`. Add `preparing` status and toast notification.

**Tech Stack:** SwiftUI, SwiftData, URLSession background downloads, iOS 17+

**Spec:** `docs/superpowers/specs/2026-03-18-download-manager-redesign.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `SashimiMobile/Downloads/Models/DownloadModels.swift` | Modify | Add `preparing` case to `DownloadStatus` |
| `SashimiMobile/Downloads/Services/DownloadPersistence.swift` | Create | Background SwiftData helper with serial queue |
| `SashimiMobile/Downloads/Services/DownloadManager.swift` | Major refactor | Serial queue, throttled progress, use DownloadPersistence, toast event |
| `SashimiMobile/Downloads/Views/DownloadButton.swift` | Modify | Handle `preparing` state |
| `SashimiMobile/Downloads/Views/DownloadsListView.swift` | Modify | Handle `preparing` state |
| `SashimiMobile/Views/Detail/MobileDetailView.swift` | Modify | Update `downloadSeason` call (no longer async) |
| `SashimiMobile/Views/Navigation/SidebarView.swift` | Modify | Add toast overlay |

---

## Chunk 1: Foundation (DownloadStatus + DownloadPersistence)

### Task 1: Add `preparing` case to DownloadStatus

**Files:**
- Modify: `SashimiMobile/Downloads/Models/DownloadModels.swift:44-50`

- [ ] **Step 1: Add preparing case**

Change the `DownloadStatus` enum from:
```swift
enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}
```
to:
```swift
enum DownloadStatus: String, Codable {
    case queued
    case preparing
    case downloading
    case paused
    case completed
    case failed
}
```

- [ ] **Step 2: Build to find all switch exhaustiveness errors**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | grep "not exhaustive" | head -20`

This will show every `switch` on `DownloadStatus` that needs updating. Note these files for later tasks.

- [ ] **Step 3: Fix exhaustiveness errors in DownloadManager.swift**

In `DownloadManager.swift`, the `startDownload` method checks `existing.status` (line 69). Add `preparing` alongside `downloading`:

Change:
```swift
            if existing.status == .completed || existing.status == .downloading || existing.status == .queued {
```
to:
```swift
            if existing.status == .completed || existing.status == .downloading || existing.status == .preparing || existing.status == .queued {
```

- [ ] **Step 4: Fix exhaustiveness errors in DownloadButton.swift**

In `DownloadButton.swift`, add `preparing` case to the `label` view (after `queued`, before `downloading`):

```swift
        case .preparing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Preparing...")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(MobileColors.textSecondary)
```

Add `preparing` to `DownloadButtonState` enum:
```swift
    private enum DownloadButtonState {
        case notDownloaded
        case queued
        case preparing
        case downloading
        case paused
        case completed
        case failed
    }
```

Add `preparing` to `handleTap()` — treat same as queued/downloading (cancel):
```swift
        case .queued, .preparing, .downloading:
            Task { await downloadManager.cancelDownload(itemId: item.id) }
```

Add `preparing` to `refreshState()`:
```swift
        case .preparing:
            downloadState = .preparing
```

- [ ] **Step 5: Fix exhaustiveness errors in DownloadsListView.swift**

In `statusLabel(for:)`, add `preparing` case after `queued`:
```swift
        case .preparing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Preparing...")
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }
```

- [ ] **Step 6: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add SashimiMobile/Downloads/Models/DownloadModels.swift SashimiMobile/Downloads/Services/DownloadManager.swift SashimiMobile/Downloads/Views/DownloadButton.swift SashimiMobile/Downloads/Views/DownloadsListView.swift
git commit -m "feat: add preparing status for download transcoding feedback

Adds 'preparing' case to DownloadStatus for when the server is
transcoding before bytes start flowing. Updates all views to handle
the new state with a spinner and 'Preparing...' label.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Create DownloadPersistence helper

**Files:**
- Create: `SashimiMobile/Downloads/Services/DownloadPersistence.swift`

- [ ] **Step 1: Create the DownloadPersistence class**

```swift
import Foundation
import SwiftData

/// Background SwiftData helper for download operations.
/// Owns a dedicated serial DispatchQueue and ModelContext to keep
/// all database work off the main actor.
final class DownloadPersistence {
    private let queue = DispatchQueue(label: "com.mondominator.sashimi.downloadPersistence")
    private var modelContext: ModelContext?

    func setModelContainer(_ container: ModelContainer) {
        queue.sync {
            self.modelContext = ModelContext(container)
        }
    }

    // MARK: - Batch Insert (for bulk downloads)

    func batchInsertQueued(
        episodes: [(item: BaseItemDto, quality: DownloadQuality)]
    ) -> [(itemId: String, quality: DownloadQuality)] {
        queue.sync {
            guard let context = modelContext else { return [] }
            var inserted: [(itemId: String, quality: DownloadQuality)] = []

            for (item, quality) in episodes {
                let itemId = item.id
                let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
                let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
                if let existing = try? context.fetch(descriptor).first {
                    if existing.status == .completed || existing.status == .downloading
                        || existing.status == .preparing || existing.status == .queued {
                        continue
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
                inserted.append((itemId: itemId, quality: quality))
            }

            try? context.save()
            return inserted
        }
    }

    // MARK: - Status Updates

    func updateStatus(itemId: String, status: DownloadStatus, errorMessage: String? = nil) {
        queue.sync {
            guard let context = modelContext else { return }
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
    }

    func updateProgress(itemId: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.progress = progress
            record.downloadedBytes = downloadedBytes
            record.totalBytes = totalBytes
            try? context.save()
        }
    }

    func markCompleted(itemId: String, videoFileName: String, totalBytes: Int64) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.videoFileName = videoFileName
            record.totalBytes = totalBytes
            record.status = .completed
            record.dateCompleted = Date()
            record.progress = 1.0
            try? context.save()
        }
    }

    func deleteRecord(itemId: String) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            if let record = try? context.fetch(descriptor).first {
                context.delete(record)
                try? context.save()
            }
        }
    }

    // MARK: - Queries

    func fetchRecord(itemId: String) -> DownloadedItem? {
        queue.sync {
            guard let context = modelContext else { return nil }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            return try? context.fetch(descriptor).first
        }
    }

    func fetchQueuedItems() -> [DownloadedItem] {
        queue.sync {
            guard let context = modelContext else { return [] }
            let predicate = #Predicate<DownloadedItem> { $0.statusRaw == "queued" }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate, sortBy: [SortDescriptor(\DownloadedItem.dateAdded)])
            return (try? context.fetch(descriptor)) ?? []
        }
    }

    // MARK: - Asset Updates

    func updatePosterFileName(itemId: String, fileName: String) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.posterFileName = fileName
            try? context.save()
        }
    }

    func updateBackdropFileName(itemId: String, fileName: String) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.backdropFileName = fileName
            try? context.save()
        }
    }

    func addSubtitle(itemId: String, language: String, displayTitle: String, subtitleIndex: Int, fileName: String) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            let subtitle = DownloadedSubtitle(
                language: language,
                displayTitle: displayTitle,
                subtitleIndex: subtitleIndex,
                fileName: fileName
            )
            record.subtitles.append(subtitle)
            try? context.save()
        }
    }

    // MARK: - Offline Progress

    func savePlaybackPosition(itemId: String, positionTicks: Int64) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.lastPlaybackPositionTicks = positionTicks
            record.needsProgressSync = true
            try? context.save()
        }
    }

    func fetchPendingSync() -> [(itemId: String, positionTicks: Int64)] {
        queue.sync {
            guard let context = modelContext else { return [] }
            let predicate = #Predicate<DownloadedItem> { $0.needsProgressSync == true }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let items = try? context.fetch(descriptor) else { return [] }
            return items.map { (itemId: $0.itemId, positionTicks: $0.lastPlaybackPositionTicks) }
        }
    }

    func clearSyncFlag(itemId: String) {
        queue.sync {
            guard let context = modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.needsProgressSync = false
            try? context.save()
        }
    }

    func deleteAllRecords() {
        queue.sync {
            guard let context = modelContext else { return }
            let descriptor = FetchDescriptor<DownloadedItem>()
            if let items = try? context.fetch(descriptor) {
                items.forEach { context.delete($0) }
                try? context.save()
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add SashimiMobile/Downloads/Services/DownloadPersistence.swift
git commit -m "feat: add DownloadPersistence background SwiftData helper

Non-isolated class with a dedicated serial DispatchQueue and single
ModelContext. All SwiftData operations go through this helper to keep
database work off the main actor.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Chunk 2: DownloadManager Refactor

### Task 3: Refactor DownloadManager — serial queue, throttled progress, use DownloadPersistence

**Files:**
- Modify: `SashimiMobile/Downloads/Services/DownloadManager.swift` (major refactor)

This is the core task. The DownloadManager keeps `@MainActor` but delegates all SwiftData to `DownloadPersistence`, adds a serial download queue, and throttles progress updates.

- [ ] **Step 1: Add DownloadPersistence, queue state, and progress throttling properties**

Add after the existing properties (after line 34):
```swift
    private let persistence = DownloadPersistence()

    // Serial download queue
    private var downloadQueue: [(item: BaseItemDto, quality: DownloadQuality)] = []
    private var currentDownloadItemId: String?

    // Progress throttling
    private var pendingProgress: [String: Double] = [:]
    private var lastProgressSave: [String: Date] = [:]
    private var progressTimer: Timer?
    private var downloadStartTimes: [String: Date] = [:] // for preparing timeout

    // Toast notification
    @Published var toastMessage: String?
```

- [ ] **Step 2: Update `setModelContainer` to initialize DownloadPersistence**

Change:
```swift
    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }
```
to:
```swift
    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
        persistence.setModelContainer(container)
    }
```

- [ ] **Step 3: Add progress timer management**

Add after `setBackgroundCompletionHandler`:
```swift
    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishProgress()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func publishProgress() {
        guard !pendingProgress.isEmpty else { return }
        activeDownloads = pendingProgress

        // Check for preparing timeout (60s with no bytes)
        let now = Date()
        for (itemId, startTime) in downloadStartTimes {
            let progress = pendingProgress[itemId] ?? 0
            if progress == 0 && now.timeIntervalSince(startTime) > 60 {
                persistence.updateStatus(itemId: itemId, status: .failed, errorMessage: "Server took too long to respond.")
                pendingProgress.removeValue(forKey: itemId)
                activeDownloads.removeValue(forKey: itemId)
                downloadStartTimes.removeValue(forKey: itemId)
                stateVersion += 1
                dequeueNext()
            }
        }
    }
```

- [ ] **Step 4: Replace `startDownload` with `enqueueDownload` and `startNextDownload`**

Replace the existing `startDownload` method (lines 59-131) with:

```swift
    func enqueueDownload(item: BaseItemDto, quality: DownloadQuality) {
        let inserted = persistence.batchInsertQueued(episodes: [(item: item, quality: quality)])
        guard !inserted.isEmpty else { return }
        downloadQueue.append((item: item, quality: quality))
        stateVersion += 1
        if currentDownloadItemId == nil {
            startNextDownload()
        }
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
        persistence.updateStatus(itemId: itemId, status: .preparing)
        pendingProgress[itemId] = 0
        downloadStartTimes[itemId] = Date()
        stateVersion += 1
        startProgressTimer()

        // Download assets in background
        downloadAssets(for: item)
    }

    private func dequeueNext() {
        currentDownloadItemId = nil
        startNextDownload()
    }
```

- [ ] **Step 5: Replace `downloadSeason` with queue-based version**

Replace:
```swift
    func downloadSeason(episodes: [BaseItemDto], quality: DownloadQuality) async {
        for episode in episodes {
            await startDownload(item: episode, quality: quality)
        }
    }
```
with:
```swift
    func downloadSeason(episodes: [BaseItemDto], quality: DownloadQuality) {
        let episodePairs = episodes.map { (item: $0, quality: quality) }
        let inserted = persistence.batchInsertQueued(episodes: episodePairs)
        guard !inserted.isEmpty else { return }

        for episode in episodes {
            if inserted.contains(where: { $0.itemId == episode.id }) {
                downloadQueue.append((item: episode, quality: quality))
            }
        }

        stateVersion += 1
        toastMessage = "Downloading \(inserted.count) episode\(inserted.count == 1 ? "" : "s")..."

        if currentDownloadItemId == nil {
            startNextDownload()
        }
    }
```

- [ ] **Step 6: Update `cancelDownload` to dequeue next**

Add after `stateVersion += 1` at the end of `deleteDownload`:
```swift
        if itemId == currentDownloadItemId {
            dequeueNext()
        } else {
            downloadQueue.removeAll { $0.item.id == itemId }
        }
```

Wait — `deleteDownload` calls `cancelDownload` then bumps stateVersion. We need the dequeue logic in `cancelDownload` instead. Update `cancelDownload` to:

```swift
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
        downloadStartTimes.removeValue(forKey: itemId)
        lastProgressSave.removeValue(forKey: itemId)

        try? DownloadFileManager.deleteItemDirectory(for: itemId)
        persistence.deleteRecord(itemId: itemId)

        // Manage queue
        if itemId == currentDownloadItemId {
            dequeueNext()
        } else {
            downloadQueue.removeAll { $0.item.id == itemId }
        }
    }
```

- [ ] **Step 7: Update `retryDownload` to use `enqueueDownload`**

Replace:
```swift
        await cancelDownload(itemId: itemId)
        await startDownload(item: freshItem, quality: quality)
```
with:
```swift
        await cancelDownload(itemId: itemId)
        enqueueDownload(item: freshItem, quality: quality)
```

- [ ] **Step 8: Update `deleteAllDownloads` to clear queue**

Add queue cleanup to `deleteAllDownloads`:
```swift
        downloadQueue.removeAll()
        currentDownloadItemId = nil
        pendingProgress.removeAll()
        downloadStartTimes.removeAll()
        lastProgressSave.removeAll()
        stopProgressTimer()
```
And replace the SwiftData section with:
```swift
        persistence.deleteAllRecords()
```

- [ ] **Step 9: Update delegate methods to use DownloadPersistence and throttled progress**

Replace the `didFinishDownloadingTo` main actor block (lines 488-513) with:
```swift
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
            self.downloadStartTimes.removeValue(forKey: itemId)
            self.lastProgressSave.removeValue(forKey: itemId)
            self.stateVersion += 1

            var map = self.taskIdMap
            map.removeValue(forKey: self.taskKey(taskId))
            self.taskIdMap = map

            self.dequeueNext()
        }
```

Replace the `didWriteData` callback (lines 528-536) with:
```swift
        Task { @MainActor in
            guard let itemId = self.taskIdMap[self.taskKey(taskId)] else { return }

            // Update in-memory progress (published on timer)
            self.pendingProgress[itemId] = progress

            // Clear preparing timeout once bytes flow
            if progress > 0 {
                self.downloadStartTimes.removeValue(forKey: itemId)
                // Ensure status is downloading (not preparing)
                if self.persistence.fetchRecord(itemId: itemId)?.status == .preparing {
                    self.persistence.updateStatus(itemId: itemId, status: .downloading)
                    self.stateVersion += 1
                }
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
```

Replace the `didCompleteWithError` main actor block with:
```swift
        Task { @MainActor in
            guard let itemId = self.taskIdMap[self.taskKey(taskId)] else { return }
            self.persistence.updateStatus(itemId: itemId, status: .failed, errorMessage: error.localizedDescription)
            self.pendingProgress.removeValue(forKey: itemId)
            self.activeDownloads.removeValue(forKey: itemId)
            self.downloadStartTimes.removeValue(forKey: itemId)

            var map = self.taskIdMap
            map.removeValue(forKey: self.taskKey(taskId))
            self.taskIdMap = map

            self.dequeueNext()
        }
```

- [ ] **Step 10: Update remaining methods to use DownloadPersistence**

Replace `downloadStatus(for:)`, `savePlaybackPosition`, `offlinePlaybackPosition`, and `syncPendingProgress` to delegate to `persistence`:

```swift
    func downloadStatus(for itemId: String) -> DownloadedItem? {
        persistence.fetchRecord(itemId: itemId)
    }

    func savePlaybackPosition(itemId: String, positionTicks: Int64) {
        persistence.savePlaybackPosition(itemId: itemId, positionTicks: positionTicks)
    }

    func offlinePlaybackPosition(for itemId: String) -> Int64? {
        guard let record = persistence.fetchRecord(itemId: itemId) else { return nil }
        return record.lastPlaybackPositionTicks > 0 ? record.lastPlaybackPositionTicks : nil
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
```

Update `downloadImage` to use persistence:
```swift
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
            // Best-effort
        }
    }
```

Update `downloadSubtitles` to use persistence — replace the SwiftData block inside the for loop:
```swift
                persistence.addSubtitle(
                    itemId: itemId,
                    language: language,
                    displayTitle: stream.displayTitle ?? language,
                    subtitleIndex: index,
                    fileName: fileName
                )
```

- [ ] **Step 11: Remove old private helper methods that are now in DownloadPersistence**

Delete: `updateStatus`, `updateProgress`, `deleteRecord` private methods (they're replaced by persistence calls).

- [ ] **Step 12: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 13: Commit**

```bash
git add SashimiMobile/Downloads/Services/DownloadManager.swift
git commit -m "refactor: serial download queue, throttled progress, background persistence

Major DownloadManager refactor:
- Serial download queue (one video at a time, rest queued)
- All SwiftData operations delegated to DownloadPersistence (off main actor)
- Progress updates throttled: pendingProgress dict → 0.5s timer → @Published
- SwiftData progress writes every 5s per item
- Preparing state with 60s timeout
- Toast notification for bulk downloads
- dequeueNext() starts next download on completion/cancel/failure

Fixes #116

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Chunk 3: View Updates + Toast

### Task 4: Update MobileDetailView for non-async downloadSeason

**Files:**
- Modify: `SashimiMobile/Views/Detail/MobileDetailView.swift`

- [ ] **Step 1: Remove Task wrapper from downloadSeason call**

The quality dialog button currently wraps in `Task { await }`. Since `downloadSeason` is now synchronous, change:
```swift
                        Button("\(quality.displayName) — \(quality.subtitle)") {
                            Task {
                                await DownloadManager.shared.downloadSeason(
                                    episodes: episodesForDownload, quality: quality
                                )
                            }
                        }
```
to:
```swift
                        Button("\(quality.displayName) — \(quality.subtitle)") {
                            DownloadManager.shared.downloadSeason(
                                episodes: episodesForDownload, quality: quality
                            )
                        }
```

- [ ] **Step 2: Update DownloadButton calls if needed**

Check if `DownloadButton` calls `startDownload` — it does (line 91, 104). These need to call `enqueueDownload` instead:

Change line 91 from:
```swift
                    await downloadManager.startDownload(item: item, quality: option)
```
to:
```swift
                    downloadManager.enqueueDownload(item: item, quality: option)
```

And line 104 from:
```swift
                Task { await downloadManager.startDownload(item: item, quality: quality.wrappedValue) }
```
to:
```swift
                downloadManager.enqueueDownload(item: item, quality: quality.wrappedValue)
```

Remove the `Task { }` wrappers since `enqueueDownload` is synchronous.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add SashimiMobile/Views/Detail/MobileDetailView.swift SashimiMobile/Downloads/Views/DownloadButton.swift
git commit -m "refactor: update views for synchronous download queue API

downloadSeason and enqueueDownload are now synchronous (queue returns
immediately), so remove Task/await wrappers from callers.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5: Add toast overlay to MainNavigationView

**Files:**
- Modify: `SashimiMobile/Views/Navigation/SidebarView.swift`

- [ ] **Step 1: Add toast overlay to MainNavigationView body**

In `MainNavigationView`, add an overlay and observe the toast. After the existing `.task { await loadLibraries() }` modifier, add:

```swift
        .overlay(alignment: .top) {
            if let message = downloadManager.toastMessage {
                Button {
                    selection = .downloads
                    downloadManager.toastMessage = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(message)
                            .font(MobileTypography.body)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation {
                            downloadManager.toastMessage = nil
                        }
                    }
                }
            }
        }
        .animation(.easeInOut, value: downloadManager.toastMessage)
```

Also add `@ObservedObject private var downloadManager = DownloadManager.shared` if not already present — check if `MainNavigationView` already has it (it doesn't currently).

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Sashimi.xcodeproj -scheme SashimiMobile -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add SashimiMobile/Views/Navigation/SidebarView.swift
git commit -m "feat: add download toast notification in nav bar

Shows a 'Downloading N episodes...' banner when bulk downloads start.
Auto-dismisses after 3 seconds. Tappable to navigate to Downloads screen.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
