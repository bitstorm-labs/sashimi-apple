import Foundation
import SwiftData

/// Background SwiftData helper for download operations.
/// Owns a dedicated serial DispatchQueue and ModelContext to keep
/// all database work off the main actor.
/// Write operations use queue.async (non-blocking). Read operations
/// that return values use queue.sync (blocking but fast).
final class DownloadPersistence {
    private let queue = DispatchQueue(label: "com.mondominator.sashimi.downloadPersistence")
    private var modelContext: ModelContext?

    func setModelContainer(_ container: ModelContainer) {
        queue.sync {
            self.modelContext = ModelContext(container)
        }
    }

    // MARK: - Status Updates (async — non-blocking)

    func updateStatus(itemId: String, status: DownloadStatus, errorMessage: String? = nil) {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
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

    func updateQuality(itemId: String, quality: DownloadQuality) {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.downloadQuality = quality
            try? context.save()
        }
    }

    func updateProgress(itemId: String, progress: Double, downloadedBytes: Int64, totalBytes: Int64) {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
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
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
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
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            if let record = try? context.fetch(descriptor).first {
                context.delete(record)
                try? context.save()
            }
        }
    }

    // MARK: - Queries (sync — returns values, but fast)

    func fetchStatus(itemId: String) -> DownloadStatus? {
        queue.sync {
            guard let context = modelContext else { return nil }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            return try? context.fetch(descriptor).first?.status
        }
    }

    func fetchQuality(itemId: String) -> DownloadQuality? {
        queue.sync {
            guard let context = modelContext else { return nil }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            return try? context.fetch(descriptor).first?.downloadQuality
        }
    }

    // MARK: - Asset Updates (async — non-blocking)

    func updatePosterFileName(itemId: String, fileName: String) {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.posterFileName = fileName
            try? context.save()
        }
    }

    func updateBackdropFileName(itemId: String, fileName: String) {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.backdropFileName = fileName
            try? context.save()
        }
    }

    func addSubtitle(itemId: String, language: String, displayTitle: String, subtitleIndex: Int, fileName: String) {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
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

    // MARK: - Offline Progress (async writes, sync reads)

    func savePlaybackPosition(itemId: String, positionTicks: Int64) {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
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
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
            let predicate = #Predicate<DownloadedItem> { $0.itemId == itemId }
            let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
            guard let record = try? context.fetch(descriptor).first else { return }
            record.needsProgressSync = false
            try? context.save()
        }
    }

    func deleteAllRecords() {
        queue.async { [weak self] in
            guard let context = self?.modelContext else { return }
            let descriptor = FetchDescriptor<DownloadedItem>()
            if let items = try? context.fetch(descriptor) {
                items.forEach { context.delete($0) }
                try? context.save()
            }
        }
    }
}
